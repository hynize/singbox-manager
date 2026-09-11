#!/usr/bin/env bash
set -eEuo pipefail

umask 077

PROJECT_NAME="${PROJECT_NAME:-Singbox Manager}"
BASE_DIR="${BASE_DIR:-/usr/local/etc/singbox-manager}"
LIB_DIR="${LIB_DIR:-/usr/local/lib/singbox-manager}"
CONFIG_FILE="${CONFIG_FILE:-${BASE_DIR}/config.json}"
NODES_FILE="${NODES_FILE:-${BASE_DIR}/nodes.json}"
SECRETS_FILE="${SECRETS_FILE:-${BASE_DIR}/secrets.json}"
SETTING_FILE="${SETTING_FILE:-${BASE_DIR}/settings.json}"
CERT_DIR="${CERT_DIR:-${BASE_DIR}/certs}"
LOG_DIR="${LOG_DIR:-${BASE_DIR}/logs}"
RUNTIME_DIR="${RUNTIME_DIR:-${BASE_DIR}/runtime}"
LOCK_FILE="${LOCK_FILE:-${BASE_DIR}/.lock}"
LOCK_TIMEOUT="${LOCK_TIMEOUT:-30}"
LOG_ROTATE_SIZE_MB="${LOG_ROTATE_SIZE_MB:-50}"
LOG_ROTATE_BACKUPS="${LOG_ROTATE_BACKUPS:-3}"

SINGBOX_BIN="${SINGBOX_BIN:-/usr/local/bin/sing-box}"
CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-/usr/local/bin/cloudflared}"
SERVICE_NAME="${SERVICE_NAME:-singbox-manager}"
DEFAULT_CDN_DOMAIN="${DEFAULT_CDN_DOMAIN:-saas.sin.fan}"

require_bash4() {
  if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "需要 bash 4.0 及以上版本（当前：${BASH_VERSION:-未知}）。" >&2
    exit 1
  fi
}

COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_RED="\033[1;31m"
COLOR_BLUE="\033[1;34m"
COLOR_RESET="\033[0m"

LOCK_HELD=false
LOCK_FD=""
LOCK_DIR_FALLBACK="${LOCK_FILE}.d"
PUBLIC_IP_CACHE="${PUBLIC_IP_CACHE:-}"
HAS_PUBLIC_IPV4=""
CLOUDFLARED_LATEST_CACHE=""

print_ok() {
  echo -e "${COLOR_GREEN}[成功]${COLOR_RESET} $*"
}

print_warn() {
  echo -e "${COLOR_YELLOW}[警告]${COLOR_RESET} $*" >&2
}

print_err() {
  echo -e "${COLOR_RED}[错误]${COLOR_RESET} $*" >&2
}

print_info() {
  echo -e "${COLOR_BLUE}[信息]${COLOR_RESET} $*"
}

fatal() {
  print_err "$*"
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    fatal "请使用 root 用户运行。"
  fi
}

setup_common_traps() {
  trap 'release_lock' EXIT
  trap 'release_lock; exit 130' INT
  trap 'release_lock; exit 143' TERM
  trap 'handle_common_error "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}" "${BASH_LINENO[0]:-0}" "$?"' ERR
}

handle_common_error() {
  local source_file="$1"
  local line_no="$2"
  local exit_code="$3"
  print_err "命令执行失败：${source_file}:${line_no}"
  # 事务回滚（auto_install 的 rep 窗口）：已清空旧节点但尚未提交时，
  # 失败必须恢复备份，避免停留"旧节点消失、新配置未启动"的不一致状态（F-02）
  if [ -n "${_AUTO_ROLLBACK_DIR:-}" ] && [ -d "${_AUTO_ROLLBACK_DIR}" ]; then
    print_err "检测到未提交的 rep 事务，正在自动恢复到安装前状态..."
    _AUTO_ROLLBACK_DIR=""
    restore_latest_backup || true
    reconcile_state || true
    render_config || true
    start_service || true
  fi
  release_lock
  exit "${exit_code}"
}

download_file() {
  local url="$1"
  local out="$2"
  # curl 失败自动换 wget 再试：弱网/单工具缺失时仍可交付
  if command_exists curl; then
    curl -fsSL --retry 3 --connect-timeout 10 "$url" -o "$out" && return 0
  fi
  if command_exists wget; then
    wget -qO "$out" --tries=3 --timeout=30 "$url" && return 0
  fi
  if command_exists curl || command_exists wget; then
    return 1
  fi
  fatal "需要安装 curl 或 wget。"
}

# 多源依次尝试下载：全部失败才返回非零（SHA256 校验由调用方执行，不因换源放松）
download_file_multi() {
  local out="$1"
  shift
  local url
  for url in "$@"; do
    [ -n "${url}" ] || continue
    if download_file "${url}" "${out}"; then
      return 0
    fi
  done
  return 1
}

sha256_file() {
  local target="$1"
  if command_exists sha256sum; then
    sha256sum "$target" | awk '{print $1}'
  elif command_exists shasum; then
    shasum -a 256 "$target" | awk '{print $1}'
  else
    openssl dgst -sha256 "$target" | awk '{print $2}'
  fi
}

verify_sha256() {
  local target="$1"
  local expected="$2"
  local actual
  actual="$(sha256_file "$target")"
  if [ "$actual" != "$expected" ]; then
    fatal "SHA256 校验失败：${target}，预期 ${expected}，实际 ${actual}"
  fi
}

ensure_dir_mode() {
  local dir="$1"
  local mode="$2"
  if install -d -m "$mode" "$dir" 2>/dev/null; then
    return 0
  fi
  mkdir -p "$dir"
  chmod "$mode" "$dir"
}

ensure_file_mode() {
  local file="$1"
  local mode="$2"
  local default_content="${3:-}"
  if [ ! -f "$file" ]; then
    printf '%s' "$default_content" >"$file"
  fi
  chmod "$mode" "$file"
}

init_storage() {
  ensure_dir_mode "${BASE_DIR}" 700
  ensure_dir_mode "${LIB_DIR}" 700
  ensure_dir_mode "${CERT_DIR}" 700
  ensure_dir_mode "${LOG_DIR}" 700
  ensure_dir_mode "${RUNTIME_DIR}" 700
  ensure_file_mode "${NODES_FILE}" 600 "{}"$'\n'
  ensure_file_mode "${SECRETS_FILE}" 600 "{}"$'\n'
  ensure_file_mode "${CONFIG_FILE}" 600 "{}"$'\n'
  ensure_file_mode "${SETTING_FILE}" 600 "{}"$'\n'
}

sanitize_permissions() {
  ensure_dir_mode "${BASE_DIR}" 700
  ensure_dir_mode "${LIB_DIR}" 700
  ensure_dir_mode "${CERT_DIR}" 700
  ensure_dir_mode "${LOG_DIR}" 700
  ensure_dir_mode "${RUNTIME_DIR}" 700

  [ -f "${NODES_FILE}" ] && chmod 600 "${NODES_FILE}"
  [ -f "${SECRETS_FILE}" ] && chmod 600 "${SECRETS_FILE}"
  [ -f "${CONFIG_FILE}" ] && chmod 600 "${CONFIG_FILE}"
  [ -f "${SETTING_FILE}" ] && chmod 600 "${SETTING_FILE}"

  find "${CERT_DIR}" -type f -name '*.key' -exec chmod 600 {} \; 2>/dev/null || true
  find "${CERT_DIR}" -type f -name '*.crt' -exec chmod 600 {} \; 2>/dev/null || true
  find "${RUNTIME_DIR}" -type f -exec chmod 600 {} \; 2>/dev/null || true
}

acquire_lock() {
  local start_time now
  init_storage

  if [ "${LOCK_HELD}" = true ]; then
    return 0
  fi

  start_time="$(date +%s)"
  if command_exists flock; then
    exec {LOCK_FD}>"${LOCK_FILE}"
    while ! flock -n "${LOCK_FD}"; do
      now="$(date +%s)"
      if [ $((now - start_time)) -ge "${LOCK_TIMEOUT}" ]; then
        fatal "在 ${LOCK_TIMEOUT} 秒内无法获取锁。"
      fi
      sleep 1
    done
  else
    while ! mkdir "${LOCK_DIR_FALLBACK}" 2>/dev/null; do
      now="$(date +%s)"
      if [ $((now - start_time)) -ge "${LOCK_TIMEOUT}" ]; then
        fatal "在 ${LOCK_TIMEOUT} 秒内无法获取锁。"
      fi
      # 陈旧锁自愈：持有 mkdir 锁的进程死亡不会自动释放，
      # 锁目录年龄超过 4 倍超时即判定为残留并强制清除
      local lock_age
      lock_age="$(stat -c %Y "${LOCK_DIR_FALLBACK}" 2>/dev/null || printf 0)"
      now="$(date +%s)"
      if [ "$((now - lock_age))" -gt "$((LOCK_TIMEOUT * 4))" ]; then
        print_warn "检测到陈旧锁目录，强制清除：${LOCK_DIR_FALLBACK}"
        rm -rf "${LOCK_DIR_FALLBACK}"
        continue
      fi
      sleep 1
    done
  fi

  LOCK_HELD=true
}

# 非阻塞尝试加锁：watchdog 等后台任务拿不到锁时静默跳过本轮而非报错退出
try_acquire_lock() {
  init_storage

  if [ "${LOCK_HELD}" = true ]; then
    return 0
  fi

  if command_exists flock; then
    exec {LOCK_FD}>"${LOCK_FILE}" || return 1
    if ! flock -n "${LOCK_FD}" 2>/dev/null; then
      eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
      LOCK_FD=""
      return 1
    fi
  else
    mkdir "${LOCK_DIR_FALLBACK}" 2>/dev/null || return 1
  fi

  LOCK_HELD=true
  return 0
}

release_lock() {
  if [ "${LOCK_HELD}" != true ]; then
    return 0
  fi

  if command_exists flock && [ -n "${LOCK_FD}" ]; then
    flock -u "${LOCK_FD}" || true
    eval "exec ${LOCK_FD}>&-"
    LOCK_FD=""
  else
    rmdir "${LOCK_DIR_FALLBACK}" 2>/dev/null || true
  fi

  LOCK_HELD=false
}

json_update() {
  local file="$1"
  shift
  local tmp
  tmp="$(mktemp "${BASE_DIR}/.json.XXXXXX")"
  if ! jq "$@" "$file" >"${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  if ! chmod 600 "${tmp}" || ! mv "${tmp}" "$file"; then
    rm -f "${tmp}"
    return 1
  fi
}

json_set_record() {
  local file="$1"
  local tag="$2"
  local json="$3"
  # shellcheck disable=SC2016
  json_update "$file" --arg tag "$tag" --argjson value "$json" '.[$tag] = $value'
}

json_delete_record() {
  local file="$1"
  local tag="$2"
  # shellcheck disable=SC2016
  json_update "$file" --arg tag "$tag" 'del(.[$tag])'
}

json_set_field() {
  local file="$1"
  local tag="$2"
  local field="$3"
  local value="$4"
  # shellcheck disable=SC2016
  json_update "$file" --arg tag "$tag" --arg field "$field" --arg value "$value" '.[$tag][$field] = $value'
}

record_value() {
  local file="$1"
  local tag="$2"
  local field="$3"
  # tr -d '\r'：防御个别平台 jq 输出 CRLF 导致取值带 \r 无法匹配
  jq -r --arg tag "$tag" --arg field "$field" '.[$tag][$field] // empty' "$file" | tr -d '\r'
}

node_value() {
  record_value "${NODES_FILE}" "$1" "$2"
}

secret_value() {
  record_value "${SECRETS_FILE}" "$1" "$2"
}

iter_node_tags() {
  jq -r 'keys[]' "${NODES_FILE}" 2>/dev/null | tr -d '\r'
}

delete_node_records() {
  local tag="$1"
  json_delete_record "${NODES_FILE}" "$tag"
  json_delete_record "${SECRETS_FILE}" "$tag"
}

# 崩溃对账：nodes 与 secrets 必须成对存在，孤儿记录一律清除
reconcile_state() {
  local tag
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    if ! jq -e --arg tag "${tag}" 'has($tag)' "${SECRETS_FILE}" >/dev/null 2>&1; then
      print_warn "对账：节点 ${tag} 缺少密钥记录，已移除。"
      json_delete_record "${NODES_FILE}" "${tag}"
    fi
  done < <(iter_node_tags)
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    if ! jq -e --arg tag "${tag}" 'has($tag)' "${NODES_FILE}" >/dev/null 2>&1; then
      print_warn "对账：孤儿密钥 ${tag}，已移除。"
      json_delete_record "${SECRETS_FILE}" "${tag}"
    fi
  done < <(jq -r 'keys[]' "${SECRETS_FILE}" 2>/dev/null | tr -d '\r')
}

# 破坏性操作前的状态快照；仅保留最近 10 份。
# 快照为"配置自包含"：除 JSON 元数据外一并备份 certs/ 证书与私钥，保证
# delete_all_nodes / rep 等破坏性操作后的 restore 能完整重建（否则恢复的
# 节点 JSON 会引用已被删除的证书文件而失效）。备份过程先在临时目录组装
# 再原子 mv，避免中断留下残缺备份。
backup_state() {
  local backup_dir tmpdir f
  backup_dir="${BASE_DIR}/backups/$(date +%Y%m%d-%H%M%S)-$(printf '%04d' $((RANDOM % 10000)))-$$"
  ensure_dir_mode "${BASE_DIR}/backups" 700
  tmpdir="$(mktemp -d "${BASE_DIR}/backups/.staging.XXXXXX")" || return 1
  mkdir -p "${tmpdir}/certs" && chmod 700 "${tmpdir}/certs"

  for f in nodes.json secrets.json config.json settings.json; do
    [ -f "${BASE_DIR}/${f}" ] && cp "${BASE_DIR}/${f}" "${tmpdir}/${f}" && chmod 600 "${tmpdir}/${f}"
  done
  # 证书/私钥（仅当存在）一并纳入，恢复时可完整回滚
  if [ -d "${CERT_DIR}" ]; then
    find "${CERT_DIR}" -maxdepth 1 -type f \( -name '*.crt' -o -name '*.key' \) -exec cp {} "${tmpdir}/certs/" \; 2>/dev/null || true
  fi
  chmod 700 "${BASE_DIR}/backups" 2>/dev/null || true
  if ! mv "${tmpdir}" "${backup_dir}"; then
    rm -rf "${tmpdir}"
    return 1
  fi

  find "${BASE_DIR}/backups" -mindepth 1 -maxdepth 1 ! -name '.staging.*' -type d 2>/dev/null | sort -r | tail -n +11 | xargs -r rm -rf
  printf '%s' "${backup_dir}"
}

restore_latest_backup() {
  local latest f
  latest="$(find "${BASE_DIR}/backups" -mindepth 1 -maxdepth 1 ! -name '.staging.*' -type d 2>/dev/null | sort | tail -n 1)"
  if [ -z "${latest}" ]; then
    print_err "没有可用的状态备份。"
    return 1
  fi
  for f in nodes.json secrets.json config.json settings.json; do
    if [ -f "${latest}/${f}" ]; then
      cp "${latest}/${f}" "${BASE_DIR}/${f}" && chmod 600 "${BASE_DIR}/${f}"
    fi
  done
  # 一并恢复证书/私钥（若该快照含 certs/），使自签/自定义证书节点完整可回滚
  if [ -d "${latest}/certs" ]; then
    ensure_dir_mode "${CERT_DIR}" 700
    local cf
    for cf in "${latest}/certs/"*.crt "${latest}/certs/"*.key; do
      [ -f "${cf}" ] || continue
      if cp "${cf}" "${CERT_DIR}/" 2>/dev/null; then
        chmod 600 "${CERT_DIR}/$(basename "${cf}")" 2>/dev/null || true
      fi
    done
  fi
  print_ok "已从备份恢复：${latest}"
}

url_encode() {
  jq -nr --arg s "$1" '$s|@uri'
}

# 域名/SNI 输入白名单：字母数字 . _ : -（冒号用于 IPv6），拒绝空格与 URI 特殊字符
is_safe_domain() {
  local value="$1"
  [ -n "${value}" ] || return 1
  [[ "${value}" =~ ^[A-Za-z0-9._:-]+$ ]] || return 1
  [[ "${value}" =~ ^[A-Za-z0-9] ]] || return 1
  [[ "${value}" =~ [A-Za-z0-9]$ ]] || return 1
  return 0
}

# 环境变量域名读取：非法值告警并回退默认（用于一键安装，避免脏输入进链接）
env_domain_or_default() {
  local __ed_key="$1"
  local __ed_default="$2"
  local __ed_value
  __ed_value="$(env_var "$__ed_key")"
  if [ -z "${__ed_value}" ]; then
    printf '%s' "${__ed_default}"
    return 0
  fi
  if is_safe_domain "${__ed_value}"; then
    printf '%s' "${__ed_value}"
  else
    print_warn "环境变量 ${__ed_key}=${__ed_value} 域名格式无效，已回退默认值 ${__ed_default}。"
    printf '%s' "${__ed_default}"
  fi
}

# 监听 :: 在 net.ipv6.bindv6only=1 时不接受 IPv4 连接，与默认 IPv4 分享链接不匹配
warn_if_bindv6only() {
  if [ -r /proc/sys/net/ipv6/bindv6only ] &&
    [ "$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || printf 0)" = "1" ]; then
    print_warn "检测到 net.ipv6.bindv6only=1：入站监听 :: 不会接受 IPv4 连接，IPv4 分享链接可能不可达。"
  fi
}

is_ip_address() {
  local ip="$1" octet
  # IPv4：四组 0-255（兼容前导零）
  if [[ "${ip}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    for octet in "${BASH_REMATCH[@]:1:4}"; do
      [ "$((10#${octet}))" -le 255 ] || return 1
    done
    return 0
  fi
  # IPv6：仅含 hex 与冒号，且 :: 至多出现一次
  if [[ "${ip}" == *:* ]] && [[ "${ip}" =~ ^[0-9a-fA-F:]+$ ]]; then
    case "${ip}" in
    *::*::*) return 1 ;;
    *) return 0 ;;
    esac
  fi
  return 1
}

is_private_ip() {
  local ip="$1"
  local lower
  lower="${ip,,}"

  if [[ "${ip}" =~ ^10\. ]] || [[ "${ip}" =~ ^127\. ]] || [[ "${ip}" =~ ^169\.254\. ]] || [[ "${ip}" =~ ^192\.168\. ]]; then
    return 0
  fi
  if [[ "${ip}" =~ ^172\.([1][6-9]|2[0-9]|3[0-1])\. ]] || [[ "${ip}" =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]]; then
    return 0
  fi
  if [[ "${ip}" =~ ^0\. ]] || [[ "${ip}" =~ ^198\.(18|19)\. ]]; then
    return 0
  fi

  case "${lower}" in
  "" | "::" | "::1" | fe80:* | fc*:* | fd*:* | 2001:db8:*) return 0 ;;
  esac

  return 1
}

wrap_host() {
  local host="$1"
  if [[ "$host" == *:* ]] && [[ "$host" != \[*\] ]]; then
    printf '[%s]' "$host"
  else
    printf '%s' "$host"
  fi
}

get_setting() {
  local key="$1"
  local default="${2:-}"
  local value
  value="$(jq -r --arg key "$key" '.[$key] // empty' "${SETTING_FILE}" 2>/dev/null | tr -d '\r')"
  printf '%s' "${value:-${default}}"
}

# 读取同名环境变量并去掉首尾空白/控制字符；sb.sh 亦定义同名函数，此处保证
# watchdog/standalone 场景（仅 source common.sh）也能使用。
env_var() {
  local __env_key="$1"
  local __env_value="${!__env_key:-}"
  printf '%s' "$(printf '%s' "${__env_value}" | tr -d '\r\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
}

# 全局调优参数读取：优先瞬时环境变量（install 时），否则回退 settings.json
# 的持久化值（rep、watchdog、重启后仍生效）。为空时返回默认值。
manager_env_or_setting() {
  local _key="$1"
  local _default="${2:-}"
  local _v
  _v="$(env_var "$_key")"
  if [ -n "${_v}" ]; then
    printf '%s' "${_v}"
    return 0
  fi
  printf '%s' "$(get_setting "$_key" "$_default")"
}

set_setting() {
  local key="$1"
  local value="$2"
  init_storage
  # shellcheck disable=SC2016
  json_update "${SETTING_FILE}" --arg key "$key" --arg value "$value" '.[$key] = $value'
}

get_public_ip() {
  local ip ipver flag url
  if [ -n "${PUBLIC_IP_CACHE}" ]; then
    printf '%s' "${PUBLIC_IP_CACHE}"
    return 0
  fi

  # 分享链接默认使用 IPv4；全局设置 ip_version 可选 auto(=v4 优先) / 4 / 6
  ipver="$(get_setting "ip_version" "4")"
  case "${ipver,,}" in
  6 | v6) ipver="6" ;;
  *) ipver="4" ;;
  esac

  local families=(4 6)
  if [ "${ipver}" = "6" ]; then
    families=(6 4)
  fi

  for ipver in "${families[@]}"; do
    if [ "${ipver}" = "4" ]; then
      flag="--ipv4"
      for url in "https://api.ipify.org" "https://ipv4.icanhazip.com"; do
        ip="$(curl -fsS --max-time 5 ${flag} "$url" 2>/dev/null | tr -d '\r\n' || true)"
        if is_ip_address "$ip" && ! is_private_ip "$ip"; then
          PUBLIC_IP_CACHE="$ip"
          printf '%s' "${PUBLIC_IP_CACHE}"
          return 0
        fi
      done
    else
      flag="--ipv6"
      for url in "https://api64.ipify.org" "https://ipv6.icanhazip.com"; do
        ip="$(curl -fsS --max-time 5 ${flag} "$url" 2>/dev/null | tr -d '\r\n' || true)"
        if is_ip_address "$ip" && ! is_private_ip "$ip"; then
          PUBLIC_IP_CACHE="$ip"
          printf '%s' "${PUBLIC_IP_CACHE}"
          return 0
        fi
      done
    fi
  done

  local fallback=""
  for ip in $(hostname -I 2>/dev/null || true); do
    if is_ip_address "$ip" && ! is_private_ip "$ip"; then
      PUBLIC_IP_CACHE="$ip"
      printf '%s' "${PUBLIC_IP_CACHE}"
      return 0
    fi
    [ -n "${fallback}" ] || fallback="$ip"
  done

  fallback="${fallback:-127.0.0.1}"
  print_warn "无法探测公网 IP，已回退到本机地址：${fallback}"
  PUBLIC_IP_CACHE="$fallback"
  printf '%s' "${PUBLIC_IP_CACHE}"
}

generate_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  elif command_exists uuidgen; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    local hex variant
    hex="$(openssl rand -hex 16)"
    variant="$(printf '%x' "$(((0x${hex:16:1} & 0x3) | 0x8))")"
    printf '%s-%s-%s-%s-%s\n' \
      "${hex:0:8}" \
      "${hex:8:4}" \
      "4${hex:13:3}" \
      "${variant}${hex:17:3}" \
      "${hex:20:12}"
  fi
}

generate_hex() {
  local bytes="${1:-8}"
  openssl rand -hex "$bytes"
}

random_ws_path() {
  printf '/%s' "$(generate_hex 4)"
}

generate_tag() {
  local prefix="$1"
  printf '%s-%s-%s' "$prefix" "$(date +%s)" "$(generate_hex 4)"
}

ensure_tls_material() {
  local tag="$1"
  local domain="$2"
  local cert_file="${CERT_DIR}/${tag}.crt"
  local key_file="${CERT_DIR}/${tag}.key"
  local san

  if [ -f "$cert_file" ] && [ -f "$key_file" ]; then
    chmod 600 "$cert_file" "$key_file"
    printf '%s|%s' "$cert_file" "$key_file"
    return 0
  fi

  if [[ "$domain" =~ ^[0-9a-fA-F:.]+$ ]]; then
    san="IP:${domain}"
  else
    san="DNS:${domain}"
  fi

  # 自签证书有效期 99 年（99×365=36135 天），配合证书指纹固定（pcs），
  # 避免客户端的证书过期告警与频繁重建。
  local extfile=""
  if ! openssl req -x509 -newkey rsa:2048 -nodes -days 36135 \
    -keyout "$key_file" \
    -out "$cert_file" \
    -subj "/CN=${domain}" \
    -addext "subjectAltName=${san}" >/dev/null 2>&1; then
    # -addext 不受支持时改用 -extfile（OpenSSL 1.0+ 均可用），仍保留 SAN
    extfile="$(mktemp "${CERT_DIR}/.ext.XXXXXX")"
    printf 'subjectAltName=%s\n' "${san}" >"${extfile}"
    if ! openssl req -x509 -newkey rsa:2048 -nodes -days 36135 \
      -keyout "$key_file" \
      -out "$cert_file" \
      -subj "/CN=${domain}" \
      -extfile "${extfile}" >/dev/null 2>&1; then
      rm -f "${extfile}"
      print_err "自签证书生成失败（含 SAN）：${domain}"
      return 1
    fi
    rm -f "${extfile}"
  fi

  chmod 600 "$cert_file" "$key_file"
  printf '%s|%s' "$cert_file" "$key_file"
}

# 提取自签证书 SHA-256 指纹（DER 形式，hex 小写）；用于分享链接 pinSHA256 固定证书，
# 替代部分新版客户端已拒绝的 allowInsecure 参数
cert_fingerprint() {
  local cert_file="$1"
  [ -f "${cert_file}" ] || return 1
  openssl x509 -in "${cert_file}" -outform DER 2>/dev/null | openssl dgst -sha256 -r 2>/dev/null | awk '{print $1}'
}

parse_trycloudflare_domain() {
  local log_file="$1"
  grep -aoE '[a-z0-9-]+\.trycloudflare\.com' "$log_file" 2>/dev/null | tail -n 1
}

wait_for_trycloudflare_domain() {
  local log_file="$1"
  local timeout="${2:-60}"
  local interval="${3:-2}"
  local elapsed=0
  local domain=""

  while [ "${elapsed}" -lt "${timeout}" ]; do
    domain="$(parse_trycloudflare_domain "$log_file" || true)"
    if [ -n "$domain" ]; then
      printf '%s' "$domain"
      return 0
    fi
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  return 1
}

# 核验临时隧道域名已进入公共 DNS（系统解析 + 1.1.1.1 DoH 双确认），
# 避免提交"日志已出现但实际不可解析"的域名（本机负缓存/解析器差异）
argo_domain_resolvable() {
  local domain="$1"
  [ -n "${domain}" ] || return 1

  # 快路径：本机解析成功即可确认（getent/host 退出码可靠）
  if command_exists getent; then
    if getent ahosts "${domain}" >/dev/null 2>&1; then
      return 0
    fi
  elif command_exists host; then
    if host "${domain}" >/dev/null 2>&1; then
      return 0
    fi
  fi

  # 本地解析不可用或未命中：查公共 DoH 记录（1.1.1.1 / dns.google 双源，绕开本机负缓存）。
  # A 与 AAAA 都查：TryCloudflare 域名可能只发布 IPv6（AAAA），仅看 A 会漏判；
  # 任一类型有记录即视为已发布。
  # 语义区分：
  #   DoH 应答"无记录"（确认未发布）           -> 返回失败，调用方重试
  #   DoH 网络不可达（无法核验，如墙内环境）   -> fail-open 放行并告警，
  #     因为 cloudflared 日志已出现域名即代表边缘注册成功，此时拒绝会让
  #     弱网机器的临时隧道永远写不进域名（v0.2.19 前的故障面）
  if command_exists curl && command_exists jq; then
    local doh_verified=0 answered=0 records source base_url record_type
    for base_url in "https://1.1.1.1/dns-query?name=${domain}." "https://dns.google/resolve?name=${domain}."; do
      for record_type in A AAAA; do
        records="$(curl -fsS --max-time 6 -H 'accept: application/dns-json' "${base_url}&type=${record_type}" 2>/dev/null | jq -r '[.Answer[]? | select(.type == 1 or .type == 28)] | length' 2>/dev/null || true)"
        [ -n "${records}" ] || continue
        doh_verified=1
        if [ "${records}" -gt 0 ]; then
          return 0
        fi
      done
      if [ "${doh_verified}" = 1 ]; then
        # 该源正常应答但 A/AAAA 均无记录 -> 确认未发布
        answered=1
        break
      fi
    done
    if [ "${doh_verified}" = 0 ]; then
      print_warn "公共 DoH 均不可达，无法核验 ${domain} 的 DNS 发布，按隧道注册结果放行。"
      return 0
    fi
    [ "${answered}" = 1 ] && return 1
  fi

  return 1
}

# 等待域名出现并确认 DNS 已发布；最多重试 retry 次（每次重新等日志域名）
wait_for_trycloudflare_domain_verified() {
  local log_file="$1"
  local timeout="${2:-60}"
  local retry="${3:-1}"
  local domain attempt

  for attempt in 0 1 2; do
    [ "${attempt}" -le "${retry}" ] || break
    domain="$(wait_for_trycloudflare_domain "${log_file}" "${timeout}" 2 || true)"
    [ -n "${domain}" ] || continue
    if argo_domain_resolvable "${domain}"; then
      printf '%s' "${domain}"
      return 0
    fi
    print_warn "临时域名 ${domain} 尚未进入公共 DNS，等待发布后重试..."
    sleep 5
  done

  return 1
}

# S2：cloudflared 崩溃退避——连续重启太频繁时按 2^(n-1) 上限 30min 等待
# 计数存 ${RUNTIME_DIR}/${tag}.restart_count，成功运行后由 ensure_argo_nodes 清零
argo_backoff_delay() {
  local fail_count="$1"
  local delay=1 i
  for ((i = 1; i < fail_count && delay < 1800; i++)); do
    delay=$((delay * 2))
  done
  [ "${delay}" -gt 1800 ] && delay=1800
  printf '%s' "${delay}"
}

# 读/写单调递增的崩溃计数文件（幂等：写失败返回非 0）
read_restart_count() {
  local tag="$1"
  local file="${RUNTIME_DIR}/${tag}.restart_count"
  [ -f "${file}" ] || { printf '0'; return 0; }
  cat "${file}" 2>/dev/null | tr -dc '0-9' | grep -E '^[0-9]+$' || printf '0'
}

bump_restart_count() {
  local tag="$1"
  local file="${RUNTIME_DIR}/${tag}.restart_count"
  local current
  current="$(read_restart_count "$tag")"
  printf '%s' "$((current + 1))" >"${file}.tmp" && chmod 600 "${file}.tmp" && mv "${file}.tmp" "${file}"
}

reset_restart_count() {
  local tag="$1"
  rm -f "${RUNTIME_DIR}/${tag}.restart_count"
}

# S1：TCP 端口活性探测。纯 bash /dev/tcp + timeout，超时默认 2 秒。
# 返回 0 表示端口可连（节点存活）。端口未指定或连接失败返回非 0。
probe_tcp_port() {
  local host="$1"
  local port="${2:-}"
  local timeout_s="${3:-2}"
  [ -n "${port}" ] || return 1
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  if command_exists timeout; then
    timeout "${timeout_s}" bash -c "exec 3<>/dev/tcp/${host}/${port}" >/dev/null 2>&1
  else
    # 环境无 timeout：直接尝试，尽力而为
    bash -c "exec 3<>/dev/tcp/${host}/${port}" >/dev/null 2>&1
  fi
}

# S1：任一节点端口存活即认为 sing-box 数据面正常。
# node_value 为空或无任何节点时返回非 0（由调用方决定是否重启，避免误杀）。
any_node_port_alive() {
  local tag port alive=1
  [ -f "${NODES_FILE}" ] || return 1
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    port="$(node_value "$tag" "port" 2>/dev/null || true)"
    [ -n "${port}" ] || continue
    if probe_tcp_port "127.0.0.1" "${port}" "${SBM_PROBE_TIMEOUT_S:-2}"; then
      alive=0
      break
    fi
  done < <(iter_node_tags)
  [ "${alive}" = 0 ] || return 1
  return 0
}

# 可选 GOGC=off（关闭 Go 逃逸堆目标，减少 GC 停顿；仅配置 GOGC=off 时启用）
go_gc_requested() {
  [ "$(manager_env_or_setting "go_gc")" = "off" ] && return 0
  return 1
}

# 网络内核调优（BBR + fq + 增大收发缓冲）：默认启用（v1.1.1 起），
# 仅 root + sysctl 生效；net_tune=0/off/no 可显式关闭。
# 支持 install 环境变量瞬时值，或持久化于 settings.json 的全局值（rep/重启后仍生效）
net_tune_requested() {
  case "$(manager_env_or_setting "net_tune")" in
  0 | off | no) return 1 ;;
  *) return 0 ;;
  esac
}

# 吸收 Actions-bbr-v3 智能带宽优化：按物理内存限制 TCP buffer 上限（MB），
# 防止小内存 VPS 因大带宽线路把缓冲区放大到 OOM
get_tcp_buffer_cap_mb() {
  local mem_kb
  mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)"
  if ! [[ "${mem_kb}" =~ ^[0-9]+$ ]]; then
    printf '%s' 64
  elif (( mem_kb < 524288 )); then
    printf '%s' 16
  elif (( mem_kb < 1048576 )); then
    printf '%s' 32
  else
    printf '%s' 64
  fi
}

# 按带宽（Mbps）与地区档位计算推荐 TCP buffer（MB，上限受内存约束）：
# asia 保守档（RTT 通常 <100ms）、overseas 大缓冲档（RTT 150-300ms）。
# 带宽非法/缺失回退 1000Mbps；缓冲区不超 get_tcp_buffer_cap_mb 上限。
calculate_net_tune_buffer_mb() {
  local bandwidth="$1" region="$2" cap_mb="$(get_tcp_buffer_cap_mb)"
  local buffer_mb=16
  bandwidth="${bandwidth%.*}"
  if ! [[ "${bandwidth}" =~ ^[0-9]+$ ]] || (( bandwidth <= 0 )); then
    bandwidth=1000
  fi
  if [ "${region}" = "overseas" ]; then
    if (( bandwidth < 500 )); then buffer_mb=16
    elif (( bandwidth < 1000 )); then buffer_mb=48
    else buffer_mb=64; fi
  else
    if (( bandwidth < 500 )); then buffer_mb=8
    elif (( bandwidth < 1000 )); then buffer_mb=12
    elif (( bandwidth < 2000 )); then buffer_mb=16
    elif (( bandwidth < 5000 )); then buffer_mb=24
    elif (( bandwidth < 10000 )); then buffer_mb=28
    else buffer_mb=32; fi
  fi
  (( buffer_mb > cap_mb )) && buffer_mb="${cap_mb}"
  printf '%s' "${buffer_mb}"
}

OOKLA_SPEEDTEST_VERSION="1.2.0"

# 查找官方 Ookla speedtest：优先 PATH，其次管理器本地下载路径
find_ookla_speedtest() {
  local bin
  if command_exists speedtest && speedtest --version 2>/dev/null | grep -q "Speedtest by Ookla"; then
    command -v speedtest
    return 0
  fi
  bin="${BASE_DIR}/bin/speedtest"
  if [ -x "${bin}" ] && "${bin}" --version 2>/dev/null | grep -q "Speedtest by Ookla"; then
    printf '%s' "${bin}"
    return 0
  fi
  return 1
}

speedtest_download_url() {
  case "$(uname -m)" in
  x86_64) printf 'https://install.speedtest.net/app/cli/ookla-speedtest-%s-linux-x86_64.tgz' "${OOKLA_SPEEDTEST_VERSION}" ;;
  aarch64) printf 'https://install.speedtest.net/app/cli/ookla-speedtest-%s-linux-aarch64.tgz' "${OOKLA_SPEEDTEST_VERSION}" ;;
  *) return 1 ;;
  esac
}

# 尽力而为安装官方 Ookla speedtest 到管理器本地目录（自包含，不触碰 /usr/local/bin）
ensure_ookla_speedtest() {
  local bin url tmp_dir
  [ -n "${NET_TUNE_SKIP_SPEEDTEST:-}" ] && return 1
  command_exists curl || command_exists wget || return 1
  command_exists tar || return 1
  url="$(speedtest_download_url)" || return 1
  mkdir -p "${BASE_DIR}/bin"
  bin="${BASE_DIR}/bin/speedtest"
  tmp_dir="$(mktemp -d "${BASE_DIR}/bin/.st.XXXXXX" 2>/dev/null)" || return 1
  if command_exists curl; then
    curl -fsSL --retry 2 --connect-timeout 10 --max-time 90 "${url}" -o "${tmp_dir}/t.tgz" || { rm -rf "${tmp_dir}"; return 1; }
  else
    wget -q --tries=2 --timeout=90 -O "${tmp_dir}/t.tgz" "${url}" || { rm -rf "${tmp_dir}"; return 1; }
  fi
  tar -xzf "${tmp_dir}/t.tgz" -C "${tmp_dir}" || { rm -rf "${tmp_dir}"; return 1; }
  mv -f "${tmp_dir}/speedtest" "${bin}" && chmod 0755 "${bin}"
  rm -rf "${tmp_dir}"
  "${bin}" --version 2>/dev/null | grep -q "Speedtest by Ookla" || { rm -f "${bin}"; return 1; }
  return 0
}

# 执行一次 Ookla 测速，解析 Upload（Mbps，取整）。测速节点延迟不参与计算（只用于带宽档位）。
run_speedtest() {
  local bin="$1" out up
  out="$("${bin}" --accept-license --accept-gdpr 2>&1 || true)"
  up="$(printf '%s' "${out}" | sed -nE 's/.*[Uu]pload:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)"
  if [[ "${up}" =~ ^[0-9]+(\.[0-9]+)?$ ]] && ! printf '%s' "${out}" | grep -qi 'FAILED\|error'; then
    printf '%s' "${up%.*}"
    return 0
  fi
  return 1
}

# 执行一次 Ookla 测速，同时解析 Upload 与 Latency（v1.2.3：延迟用于档位推断与交互确认）。
# 输出 "upload latency"（upload 取整，latency 不可用为空），upload 解析失败返回非零。
run_speedtest_metrics() {
  local bin="$1" out up lat
  out="$("${bin}" --accept-license --accept-gdpr 2>&1 || true)"
  up="$(printf '%s' "${out}" | sed -nE 's/.*[Uu]pload:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)"
  lat="$(printf '%s' "${out}" | sed -nE 's/.*[Ll]atency:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)"
  if [[ "${up}" =~ ^[0-9]+(\.[0-9]+)?$ ]] && ! printf '%s' "${out}" | grep -qi 'FAILED\|error'; then
    printf '%s %s' "${up%.*}" "${lat%.[0-9]*}"
    return 0
  fi
  return 1
}

# 自动测速（尽力而为）：找到或安装 Ookla speedtest 后测一次带宽
measure_net_bandwidth() {
  local bin up
  if ! bin="$(find_ookla_speedtest)"; then
    ensure_ookla_speedtest || return 1
    bin="$(find_ookla_speedtest)" || return 1
  fi
  if command_exists timeout; then
    if [ -n "${NET_TUNE_SPEEDTEST_TIMEOUT:-}" ]; then
      up="$(timeout "${NET_TUNE_SPEEDTEST_TIMEOUT}" bash -c "$(declare -f run_speedtest); run_speedtest '$bin'" 2>/dev/null || true)"
    else
      up="$(timeout 90 bash -c "$(declare -f run_speedtest); run_speedtest '$bin'" 2>/dev/null || true)"
    fi
  else
    up="$(run_speedtest "${bin}" 2>/dev/null || true)"
  fi
  [[ "${up}" =~ ^[0-9]+$ ]] && { printf '%s' "${up}"; return 0; }
  return 1
}

# 自动测速并解析 带宽+延迟（v1.2.3）：输出 "upload latency"，供档位推断与交互确认。
# 延迟解析失败不影响带宽输出（简称空置）；整体失败返回非零。
measure_net_metrics() {
  local bin out up lat
  if ! bin="$(find_ookla_speedtest)"; then
    ensure_ookla_speedtest || return 1
    bin="$(find_ookla_speedtest)" || return 1
  fi
  if command_exists timeout; then
    if [ -n "${NET_TUNE_SPEEDTEST_TIMEOUT:-}" ]; then
      out="$(timeout "${NET_TUNE_SPEEDTEST_TIMEOUT}" bash -c "$(declare -f run_speedtest_metrics); run_speedtest_metrics '$bin'" 2>/dev/null || true)"
    else
      out="$(timeout 90 bash -c "$(declare -f run_speedtest_metrics); run_speedtest_metrics '$bin'" 2>/dev/null || true)"
    fi
  else
    out="$(run_speedtest_metrics "${bin}" 2>/dev/null || true)"
  fi
  up="${out%% *}"
  lat="${out#* }"
  [[ "${up}" =~ ^[0-9]+$ ]] && { printf '%s %s' "${up}" "${lat}"; return 0; }
  return 1
}

# 按延迟推断地区档位（v1.2.3）：延迟 <150ms 视为 asia 保守档，>=150ms 视为 overseas 大缓冲档。
# 未知延迟回退 asia。用于未显式设置 net_tune_region 时自动推断。
infer_net_tune_region() {
  local latency="${1:-}"
  if [[ "${latency}" =~ ^[0-9]+$ ]] && [ "${latency}" -ge 150 ]; then
    printf '%s' "overseas"
  else
    printf '%s' "asia"
  fi
}

# 交互式确认（v1.2.3）：网络不佳时自动测速误差大，测速与延迟出来后给用户确认/覆写的机会。
# 仅交互式终端（stdin 为 TTY）且 NET_TUNE_SKIP_CONFIRM=1 未设置时启用；否则原样返回。
# 输出格式："带宽 延迟"（空格分隔），供调用方继续套用档位与 buffer 计算。
net_tune_confirm_measurement() {
  local bandwidth="$1" latency="$2" region="$3" cap_mb buffer_mb
  local answer new_bw new_lat
  if [ "${SBM_TEST_MODE:-0}" = "1" ] || [ ! -t 0 ] || [ "${NET_TUNE_SKIP_CONFIRM:-0}" = "1" ]; then
    printf '%s %s' "${bandwidth}" "${latency}"
    return 0
  fi
  cap_mb="$(get_tcp_buffer_cap_mb)"
  buffer_mb="$(calculate_net_tune_buffer_mb "${bandwidth}" "${region}")"
  echo >&2
  print_info "net_tune 自动测速结果：约 ${bandwidth} Mbps${latency:+，延迟约 ${latency} ms}（${region} 档）。" >&2
  print_info "推荐 TCP 缓冲：${buffer_mb}MB（内存上限 ${cap_mb}MB 内）。" >&2
  while true; do
    print_info "网络不佳时自动测速常有误差，可输入  新带宽 新延迟  覆写。" >&2
    read -r -p "直接回车确认，或输入新值（格式：带宽 延迟，如 500 120）: " answer || true
    answer="$(printf '%s' "${answer}" | tr -d '\r\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if [ -z "${answer}" ]; then
      break
    fi
    new_bw="$(printf '%s' "${answer}" | awk '{print $1}')"
    new_lat="$(printf '%s' "${answer}" | awk '{print $2}')"
    if [[ "${new_bw}" =~ ^[0-9]+$ ]] && [ "${new_bw}" -gt 0 ]; then
      bandwidth="${new_bw}"
      [[ "${new_lat}" =~ ^[0-9]+$ ]] && latency="${new_lat}"
      print_ok "已覆写：带宽 ${bandwidth} Mbps，延迟 ${latency:-未测} ms。" >&2
      break
    fi
    print_warn "输入无效，应为两个正整数（带宽 延迟）。"
  done
  printf '%s %s' "${bandwidth}" "${latency}"
}

# 应用网络调优 sysctl 集合：逐项写入、写后回读校验，并把配置持久化到 /etc/sysctl.d/
# 供重启后自动加载（仅 root 且目录可写时）。写失败但键本身不存在（如部分精简内核
# 缺 tcp_slow_start_after_idle）视为无害；键存在却写失败或回读不符才判失败。
apply_sysctls() {
  local buffer_bytes="$1" k v ok=true err=""
  local -a pairs=(
    net.core.rmem_max "${buffer_bytes}"
    net.core.wmem_max "${buffer_bytes}"
    net.core.default_qdisc fq
    net.ipv4.tcp_congestion_control bbr
    net.ipv4.tcp_rmem "4096 87380 ${buffer_bytes}"
    net.ipv4.tcp_wmem "4096 65536 ${buffer_bytes}"
    net.ipv4.tcp_limit_output_bytes 4194304
    net.ipv4.tcp_slow_start_after_idle 0
  )
  local i
  for ((i = 0; i < ${#pairs[@]}; i += 2)); do
    k="${pairs[i]}"
    v="${pairs[i + 1]}"
    if ! sysctl -w "${k}=${v}" >/dev/null 2>&1; then
      # 键不存在（精简内核）：无害，跳过；键存在但写入被拒：记失败
      if [ -n "$(sysctl -n "${k}" 2>/dev/null)" ]; then
        ok=false
        err="${err}${k} "
      fi
    fi
  done

  # 核心项写后回读校验（这些键所有常规内核均存在）
  [ "$(sysctl -n net.core.rmem_max 2>/dev/null)" = "${buffer_bytes}" ] || { ok=false; err="${err}rmem_max "; }
  [ "$(sysctl -n net.core.wmem_max 2>/dev/null)" = "${buffer_bytes}" ] || { ok=false; err="${err}wmem_max "; }
  [ "$(sysctl -n net.core.default_qdisc 2>/dev/null)" = "fq" ] || { ok=false; err="${err}default_qdisc "; }
  [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ] || { ok=false; err="${err}tcp_congestion_control "; }
  [ "$(sysctl -n net.ipv4.tcp_limit_output_bytes 2>/dev/null)" = "4194304" ] || { ok=false; err="${err}tcp_limit_output_bytes "; }

  if [ -d /etc/sysctl.d ] && [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then
    {
      echo "# singbox-manager net_tune（v1.2.1 智能网络调优，重启后自动加载）"
      echo "net.core.rmem_max=${buffer_bytes}"
      echo "net.core.wmem_max=${buffer_bytes}"
      echo "net.core.default_qdisc=fq"
      echo "net.ipv4.tcp_congestion_control=bbr"
      echo "net.ipv4.tcp_rmem=4096 87380 ${buffer_bytes}"
      echo "net.ipv4.tcp_wmem=4096 65536 ${buffer_bytes}"
      echo "net.ipv4.tcp_limit_output_bytes=4194304"
      echo "net.ipv4.tcp_slow_start_after_idle=0"
    } >"/etc/sysctl.d/99-singbox-manager-net-tune.conf" 2>/dev/null
  fi

  if [ "${ok}" = "true" ]; then
    print_ok "已应用网络调优：BBR + fq + $((buffer_bytes / 1024 / 1024))MB 缓冲（tcp_limit_output_bytes=4MB、slow_start_after_idle=0），并已持久化到 /etc/sysctl.d/。"
  else
    print_warn "net_tune：sysctl 写入/回读校验失败（${err}），可能容器或精简内核限制不可调。"
  fi
}

apply_network_tune() {
  net_tune_requested || return 0
  [ "$(id -u 2>/dev/null || echo 1)" = "0" ] || return 0
  command_exists sysctl || return 0
  # 冒烟测试环境不执行真实 sysctl/测速（免网络依赖与副作用）
  if [ "${SBM_TEST_MODE:-0}" = "1" ]; then
    return 0
  fi
  local region bandwidth buffer_mb buffer_bytes cap_mb latency metric region_set
  local explicit_region

  # 地区档位：显式 net_tune_region 优先；否则首测时按延迟自动推断（v1.2.3）
  explicit_region="$(manager_env_or_setting "net_tune_region" "")"
  case "${explicit_region}" in
  asia | overseas) region="${explicit_region}" ;;
  *) region="" ;;
  esac

  buffer_mb="$(get_setting "net_tune_buffer_mb")"
  bandwidth="$(get_setting "net_tune_bandwidth_mbps")"
  if [ -n "${buffer_mb}" ] && [[ "${buffer_mb}" =~ ^[0-9]+$ ]]; then
    : # 沿用已测速并持久化的 buffer
  else
    # 首次运行：优先显式带宽，否则自动测速（含延迟），再按档位换算 buffer 并持久化
    bandwidth="${bandwidth:-}"
    if [ -z "${bandwidth}" ]; then
      bandwidth="$(env_var "net_tune_bandwidth_mbps")"
    fi
    latency=""
    if [ -n "${bandwidth}" ] && [[ "${bandwidth}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      : # 用户给定带宽，跳过测速
    elif [ -z "${NET_TUNE_SKIP_SPEEDTEST:-}" ]; then
      print_ok "net_tune：正在自动测速以智能优化 TCP 缓冲（首次运行，可 NET_TUNE_SKIP_SPEEDTEST=1 跳过）..."
      if metric="$(measure_net_metrics)"; then
        bandwidth="${metric%% *}"
        latency="${metric#* }"
        # 档位未显式设置时按延迟自动推断（延迟未知回退 asia）
        if [ -z "${region}" ]; then
          region="$(infer_net_tune_region "${latency}")"
          region_set="yes"
        fi
        # 交互确认：网络不佳时测速/延迟误差大，允许人工覆写（仅交互式终端）
        metric="$(net_tune_confirm_measurement "${bandwidth}" "${latency}" "${region}")"
        bandwidth="${metric%% *}"
        latency="${metric#* }"
        # 覆写后若档位为自动推断值，则按最新延迟重推
        if [ "${region_set:-}" = "yes" ]; then
          region="$(infer_net_tune_region "${latency}")"
        fi
        print_ok "net_tune：测速结果 带宽约 ${bandwidth} Mbit/s${latency:+、延迟约 ${latency} ms}（${region} 档）。"
      else
        print_warn "自动测速不可用（缺少 speedtest 或网络受限），按带宽 1000Mbps 档位优化。"
        bandwidth="1000"
      fi
    else
      bandwidth="1000"
    fi
    [ -z "${region}" ] && region="asia"
    cap_mb="$(get_tcp_buffer_cap_mb)"
    buffer_mb="$(calculate_net_tune_buffer_mb "${bandwidth}" "${region}")"
    set_setting "net_tune_bandwidth_mbps" "${bandwidth}"
    set_setting "net_tune_latency_ms" "${latency:-}"
    set_setting "net_tune_region" "${region}"
    set_setting "net_tune_buffer_mb" "${buffer_mb}"
    print_ok "net_tune：带宽约 ${bandwidth} Mbps（${region} 档），内存上限 ${cap_mb}MB，推荐 TCP 缓冲 ${buffer_mb}MB。"
  fi

  buffer_bytes=$((buffer_mb * 1024 * 1024))
  apply_sysctls "${buffer_bytes}"
}

has_public_ipv4() {
  if [ -n "${HAS_PUBLIC_IPV4}" ]; then
    [ "${HAS_PUBLIC_IPV4}" = "yes" ]
    return
  fi

  local ip
  ip="$(curl -fsS --max-time 5 --ipv4 "https://api64.ipify.org" 2>/dev/null | tr -d '\r\n' || true)"
  if is_ip_address "${ip}" && ! is_private_ip "${ip}"; then
    HAS_PUBLIC_IPV4="yes"
    return 0
  fi

  HAS_PUBLIC_IPV4="no"
  return 1
}

argo_edge_ip_version() {
  if has_public_ipv4; then
    printf '4'
  else
    printf '6'
  fi
}

cloudflared_latest_release_json() {
  if [ -n "${CLOUDFLARED_LATEST_CACHE}" ]; then
    printf '%s' "${CLOUDFLARED_LATEST_CACHE}"
    return 0
  fi

  local json
  json="$(curl -fsSL --retry 3 --retry-delay 2 --max-time 30 -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" 2>/dev/null || true)"
  [ -n "${json}" ] || return 1

  CLOUDFLARED_LATEST_CACHE="${json}"
  printf '%s' "${json}"
}

cloudflared_latest_version() {
  local json tag
  # 首选 GitHub API（含 digest 数据）；不可用时回退 jsdelivr 镜像索引（仅版本号）
  json="$(cloudflared_latest_release_json 2>/dev/null || true)"
  if [ -n "${json}" ]; then
    tag="$(printf '%s' "${json}" | jq -r '.tag_name // empty' 2>/dev/null || true)"
    if [ -n "${tag}" ]; then
      printf '%s' "${tag}"
      return 0
    fi
  fi
  tag="$(curl -fsSL --retry 2 --max-time 20 "https://data.jsdelivr.com/v1/package/gh/cloudflare/cloudflared" 2>/dev/null | jq -r '.versions[]? | select(type == "string" and test("^[0-9]{4}\\.[0-9]+\\.[0-9]+$"))' 2>/dev/null | head -n 1 || true)"
  [ -n "${tag}" ] || return 1
  printf '%s' "${tag}"
}

cloudflared_latest_digest() {
  local asset="$1"
  local json digest
  json="$(cloudflared_latest_release_json 2>/dev/null || true)"
  [ -n "${json}" ] || return 1
  digest="$(printf '%s' "${json}" | jq -r --arg name "${asset}" '.assets[] | select(.name == $name) | .digest // empty' 2>/dev/null | sed 's/^sha256://')"
  [ -n "${digest}" ] || return 1
  printf '%s' "${digest}"
}

cloudflared_installed_version() {
  local out
  out="$("${CLOUDFLARED_BIN}" version 2>/dev/null | head -n 1 || true)"
  printf '%s' "${out#cloudflared version }"
}

write_pid_file() {
  local pid_file="$1"
  local pid="$2"
  printf '%s\n' "$pid" >"$pid_file"
  chmod 600 "$pid_file"
}

read_pid_file() {
  local pid_file="$1"
  local content
  [ -f "$pid_file" ] || return 1
  content="$(tr -d ' \r\n' <"$pid_file")"
  # PID 文件只接受纯数字，拒绝负数、特殊值与被污染的内容
  [[ "${content}" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "${content}"
}

# 校验 PID 是否仍指向预期二进制，防止进程死亡后 PID 被复用而误杀无关进程。
# 兼容 in-place 升级：二进制被替换（rm 后重写同一路径）且旧进程仍在运行时，
# /proc/PID/exe 会解析为 "<path> (deleted)".此时该进程仍是"我们之前启动的实例"，
# 若因末尾多了" (deleted)"就拒绝杀掉，会导致旧进程残留、与重启后的新实例并存
# （同端口/同隧道域名冲突）。因此路径相等或"路径 + ' (deleted)'"均视为命中。
pid_matches_binary() {
  local pid="$1"
  local binary="$2"
  [ -n "${pid}" ] && [ -n "${binary}" ] || return 1
  local exe=""
  exe="$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)"
  [ -n "${exe}" ] || return 1
  [ "${exe}" = "${binary}" ] || [ "${exe}" = "${binary} (deleted)" ]
}

# 判断 PID 是否仍是"我们启动的实例"：存活且（/proc 可用时）指向预期二进制。
# /proc 不可用（无 root/精简系统）时退化为仅 kill -0 存活判断（尽力而为）。
# 用于 watchdog/service_state 的存活检测，避免 PID 复用导致漏重启或误判。
pid_matches_binary_or_alive() {
  local pid="$1"
  local binary="$2"
  [ -n "${pid}" ] || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  if [ ! -d /proc ]; then
    return 0
  fi
  pid_matches_binary "${pid}" "${binary}"
}

kill_pid_file() {
  local pid_file="$1"
  local expect="${2:-}"
  local pid
  pid="$(read_pid_file "${pid_file}" 2>/dev/null || true)"
  rm -f "${pid_file}"
  [ -n "${pid}" ] || return 0

  # 提供预期二进制时先做身份校验（需 /proc，root 下可用）
  if [ -n "${expect}" ] && [ -d /proc ] && ! pid_matches_binary "${pid}" "${expect}"; then
    if kill -0 "${pid}" 2>/dev/null; then
      print_warn "PID ${pid} 已不属于 ${expect}（疑似 PID 复用），跳过终止。"
    fi
    return 0
  fi

  kill "${pid}" >/dev/null 2>&1 || return 0
  # TERM 后等待退出，最多 5 秒，仍存活则 KILL
  for _ in 1 2 3 4 5; do
    kill -0 "${pid}" 2>/dev/null || return 0
    sleep 1
  done
  kill -9 "${pid}" >/dev/null 2>&1 || true
  return 0
}

rotate_log_file() {
  local file="$1"
  local size max_bytes idx

  [ -f "$file" ] || return 1
  size="$(wc -c <"$file" 2>/dev/null | tr -d '[:space:]')"
  [ -n "$size" ] || return 1

  max_bytes=$((LOG_ROTATE_SIZE_MB * 1024 * 1024))
  if [ "$size" -lt "$max_bytes" ]; then
    return 1
  fi

  if [ "${LOG_ROTATE_BACKUPS}" -le 0 ]; then
    : >"$file" || return 1
    chmod 600 "$file" || return 1
    return 0
  fi

  rm -f "${file}.${LOG_ROTATE_BACKUPS}"

  if [ "${LOG_ROTATE_BACKUPS}" -gt 1 ]; then
    idx=$((LOG_ROTATE_BACKUPS - 1))
    while [ "$idx" -ge 1 ]; do
      if [ -f "${file}.${idx}" ]; then
        mv "${file}.${idx}" "${file}.$((idx + 1))" || return 1
      fi
      idx=$((idx - 1))
    done
  fi

  cp "$file" "${file}.1" || return 1
  : >"$file" || return 1
  chmod 600 "$file" "${file}.1" || return 1
  return 0
}

# 按 min(可见内存, cgroup memory.max/high) 计算 Go 运行时软内存上限（MiB），
# 防止小内存机/受限容器（cgroup 上限低于物理内存）OOM；
# 结果不低于下限，上限比例可被 SBM_GOMEM_LIMIT_PCT 覆盖（默认 45%）
compute_go_mem_limit_mb() {
  local pct="${SBM_GOMEM_LIMIT_PCT:-45}"
  local floor_mb="${SBM_GOMEM_FLOOR_MB:-32}"
  local total_kb limit_mb v

  total_kb="$(awk '/^(MemTotal|MemTotal:)/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)"
  [ -n "${total_kb}" ] || total_kb=0

  local f
  for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.high; do
    [ -r "${f}" ] || continue
    v="$(tr -d ' \r\n' <"${f}" 2>/dev/null || true)"
    [ -n "${v}" ] || continue
    [ "${v}" = "max" ] && continue
    [[ "${v}" =~ ^[0-9]+$ ]] || continue
    [ "${v}" -le 0 ] && continue
    if [ "${total_kb}" -le 0 ] || [ "$((v / 1024))" -lt "${total_kb}" ]; then
      total_kb=$((v / 1024))
    fi
  done

  if [ "${total_kb}" -le 0 ]; then
    return 1
  fi

  limit_mb=$((total_kb * 1024 * pct / 100 / 1024 / 1024))
  if [ "${limit_mb}" -lt "${floor_mb}" ]; then
    limit_mb="${floor_mb}"
  fi
  printf '%s' "${limit_mb}"
}

# 输出注入用 GOMEMLIMIT 值；无法探测内存时输出空（不注入）
go_mem_limit_value() {
  local mb
  mb="$(compute_go_mem_limit_mb 2>/dev/null || true)"
  [ -n "${mb}" ] || return 0
  printf '%sMiB' "${mb}"
}

build_share_link() {
  local tag="$1"
  local public_ip="${2:-}"
  local protocol name port host uuid password username fp
  local reality_server public_key short_id ws_path preferred_domain endpoint_domain host_domain tls_server cert_mode ws_mode cdn_port cdn_sni ext

  protocol="$(node_value "$tag" "protocol")"
  name="$(node_value "$tag" "name")"
  port="$(node_value "$tag" "port")"
  # 支持外部一次性传入解析好的公网 IP（第 2 参），便于订阅/列表在一次网络探测后
  # 复用，避免 N 个节点重复探测；未传时回退进程内缓存探测。
  public_ip="${public_ip:-$(get_public_ip)}"
  host="$(wrap_host "$public_ip")"

  case "$protocol" in
  vless-reality)
    uuid="$(secret_value "$tag" "uuid")"
    reality_server="$(url_encode "$(node_value "$tag" "reality_server")")"
    public_key="$(url_encode "$(node_value "$tag" "public_key")")"
    short_id="$(url_encode "$(node_value "$tag" "short_id")")"
    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
      "$uuid" "$host" "$port" "$reality_server" "$public_key" "$short_id" "$(url_encode "$name")"
    ;;
  vless-ws-tls)
    uuid="$(secret_value "$tag" "uuid")"
    ws_path="$(node_value "$tag" "ws_path")"
    preferred_domain="$(node_value "$tag" "preferred_domain")"
    host_domain="$(node_value "$tag" "host_domain")"
    cert_mode="$(node_value "$tag" "certificate_mode")"
    ws_mode="$(node_value "$tag" "ws_mode")"
    cdn_port="$(node_value "$tag" "cdn_port")"
    cdn_sni="$(node_value "$tag" "cdn_sni")"
    ws_mode="${ws_mode:-direct}"
    cdn_port="${cdn_port:-443}"
    if [ "${ws_mode}" = "cdn" ]; then
      # CDN 中转模式：客户端连 cdn_host:cdn_port，SNI/Host 走回源域名（cdn_sni，默认同连接地址），
      # 由前置 CDN 根据 SNI/Host 识别并回源到本机。
      if [ -z "${preferred_domain}" ] || [ "${preferred_domain}" = "${DEFAULT_CDN_DOMAIN}" ]; then
        print_warn "WS-TLS 节点 ${tag} 使用默认优选域名 ${DEFAULT_CDN_DOMAIN}：仅当该域名已接入本机前置 CDN 时可用，否则请把 cdn_host 设为你自己的域名或改用 ws_mode=direct 直连。"
      fi
      printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s' \
        "$uuid" "$(wrap_host "$preferred_domain")" "$cdn_port" \
        "$(url_encode "${cdn_sni:-${preferred_domain}}")" "$(url_encode "${cdn_sni:-${preferred_domain}}")" "$(url_encode "$ws_path")"
    else
      # 直连模式：客户端连服务器 IP + wspt，SNI/Host 走 WS Host 域名（自签证书跳过校验）
      printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s' \
        "$uuid" "$host" "$port" \
        "$(url_encode "$host_domain")" "$(url_encode "$host_domain")" "$(url_encode "$ws_path")"
    fi
    # 自签证书固定指纹仅在直连模式有意义：客户端直连本机、面对的就是该自签证书。
    # CDN 模式客户端面对的是前置 CDN（如 Cloudflare）边缘的公开证书，不能固定源站自签指纹，否则必然校验失败。
    if [ "$cert_mode" = "self-signed" ] && [ "${ws_mode}" != "cdn" ]; then
      # 自签证书固定指纹（新版 Xray/v2rayN 已拒绝 allowInsecure，改用 pinnedPeerCertSha256）；
      # 无证书文件（旧节点）时回退 allowInsecure=1
      fp="$(cert_fingerprint "$(node_value "$tag" "certificate_path")" 2>/dev/null || true)"
      if [ -n "${fp}" ]; then
        printf '&pcs=%s' "${fp}"
      else
        printf '&allowInsecure=1'
      fi
    fi
    printf '#%s' "$(url_encode "$name")"
    ;;
  anytls)
    password="$(secret_value "$tag" "password")"
    tls_server="$(url_encode "$(node_value "$tag" "tls_server")")"
    cert_mode="$(node_value "$tag" "certificate_mode")"
    # 自签证书：insecure=1 跳过校验；type/headerType 声明 TCP 传输，兼容主流客户端解析
    if [ "$cert_mode" = "self-signed" ]; then
      ext="insecure=1&"
    else
      ext=""
    fi
    printf 'anytls://%s@%s:%s?%ssecurity=tls&sni=%s&type=tcp&headerType=none' \
      "$(url_encode "$password")" "$host" "$port" "$ext" "$tls_server"
    printf '#%s' "$(url_encode "$name")"
    ;;
  vless-argo)
    uuid="$(secret_value "$tag" "uuid")"
    ws_path="$(node_value "$tag" "ws_path")"
    preferred_domain="$(node_value "$tag" "preferred_domain")"
    cdn_port="$(node_value "$tag" "cdn_port")"
    cdn_port="${cdn_port:-443}"
    endpoint_domain="$(node_value "$tag" "endpoint_domain")"
    if [ -z "${endpoint_domain}" ] || [ "${endpoint_domain}" = "待分配.example.com" ]; then
      print_warn "节点 ${tag} 的 Argo 域名尚未分配（隧道可能未连上），链接暂不可用；稍后重试 sbm list。"
      return 0
    fi
    printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s#%s' \
      "$uuid" "$(wrap_host "$preferred_domain")" "$cdn_port" \
      "$(url_encode "$endpoint_domain")" "$(url_encode "$endpoint_domain")" "$(url_encode "$ws_path")" "$(url_encode "$name")"
    ;;
  tuic-v5)
    uuid="$(secret_value "$tag" "uuid")"
    password="$(secret_value "$tag" "password")"
    tls_server="$(url_encode "$(node_value "$tag" "tls_server")")"
    cert_mode="$(node_value "$tag" "certificate_mode")"
    printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&alpn=h3&sni=%s' \
      "$uuid" "$(url_encode "$password")" "$host" "$port" "$tls_server"
    if [ "$cert_mode" = "self-signed" ]; then
      printf '&allow_insecure=1'
    fi
    printf '#%s' "$(url_encode "$name")"
    ;;
  hy2)
    password="$(secret_value "$tag" "password")"
    tls_server="$(url_encode "$(node_value "$tag" "tls_server")")"
    cert_mode="$(node_value "$tag" "certificate_mode")"
    printf 'hysteria2://%s@%s:%s?sni=%s' \
      "$(url_encode "$password")" "$host" "$port" "$tls_server"
    if [ "$cert_mode" = "self-signed" ]; then
      # 自签优先固定证书指纹（新版客户端已拒绝 insecure）；无指纹再退回 insecure=1
      fp="$(cert_fingerprint "$(node_value "$tag" "certificate_path")" 2>/dev/null || true)"
      if [ -n "${fp}" ]; then
        printf '&pinSHA256=%s' "${fp}"
      else
        printf '&insecure=1'
      fi
    fi
    printf '#%s' "$(url_encode "$name")"
    ;;
  socks5)
    username="$(node_value "$tag" "username")"
    password="$(secret_value "$tag" "password")"
    printf 'socks5://%s:%s@%s:%s#%s' \
      "$(url_encode "$username")" "$(url_encode "$password")" "$host" "$port" "$(url_encode "$name")"
    ;;
  esac
}

build_vless_argo_link() {
  build_share_link "$1"
}
