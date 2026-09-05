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
  release_lock
  exit "${exit_code}"
}

download_file() {
  local url="$1"
  local out="$2"
  if command_exists curl; then
    curl -fsSL --retry 3 --connect-timeout 10 "$url" -o "$out"
  elif command_exists wget; then
    wget -qO "$out" "$url"
  else
    fatal "需要安装 curl 或 wget。"
  fi
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

# 破坏性操作前的状态快照；仅保留最近 10 份
backup_state() {
  local backup_dir
  backup_dir="${BASE_DIR}/backups/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${backup_dir}" && chmod 700 "${BASE_DIR}/backups" "${backup_dir}"
  local f
  for f in nodes.json secrets.json config.json settings.json; do
    [ -f "${BASE_DIR}/${f}" ] && cp "${BASE_DIR}/${f}" "${backup_dir}/${f}"
  done
  find "${BASE_DIR}/backups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r | tail -n +11 | xargs -r rm -rf
  printf '%s' "${backup_dir}"
}

restore_latest_backup() {
  local latest f
  latest="$(find "${BASE_DIR}/backups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1)"
  if [ -z "${latest}" ]; then
    print_err "没有可用的状态备份。"
    return 1
  fi
  for f in nodes.json secrets.json config.json settings.json; do
    if [ -f "${latest}/${f}" ]; then
      cp "${latest}/${f}" "${BASE_DIR}/${f}" && chmod 600 "${BASE_DIR}/${f}"
    fi
  done
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

  local extfile=""
  if ! openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$key_file" \
    -out "$cert_file" \
    -subj "/CN=${domain}" \
    -addext "subjectAltName=${san}" >/dev/null 2>&1; then
    # -addext 不受支持时改用 -extfile（OpenSSL 1.0+ 均可用），仍保留 SAN
    extfile="$(mktemp "${CERT_DIR}/.ext.XXXXXX")"
    printf 'subjectAltName=%s\n' "${san}" >"${extfile}"
    if ! openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
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
  json="$(cloudflared_latest_release_json)" || return 1
  tag="$(printf '%s' "${json}" | jq -r '.tag_name // empty')"
  [ -n "${tag}" ] || return 1
  printf '%s' "${tag}"
}

cloudflared_latest_digest() {
  local asset="$1"
  local json digest
  json="$(cloudflared_latest_release_json)" || return 1
  digest="$(printf '%s' "${json}" | jq -r --arg name "${asset}" '.assets[] | select(.name == $name) | .digest // empty' | sed 's/^sha256://')"
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

# 校验 PID 是否仍指向预期二进制，防止进程死亡后 PID 被复用而误杀无关进程
pid_matches_binary() {
  local pid="$1"
  local binary="$2"
  [ -n "${pid}" ] && [ -n "${binary}" ] || return 1
  local exe=""
  exe="$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)"
  [ -n "${exe}" ] || return 1
  [ "${exe}" = "${binary}" ]
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

build_share_link() {
  local tag="$1"
  local protocol name port public_ip host uuid password username
  local reality_server public_key short_id ws_path preferred_domain endpoint_domain host_domain tls_server cert_mode

  protocol="$(node_value "$tag" "protocol")"
  name="$(node_value "$tag" "name")"
  port="$(node_value "$tag" "port")"
  public_ip="$(get_public_ip)"
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
    if [ -z "${preferred_domain}" ] || [ "${preferred_domain}" = "${DEFAULT_CDN_DOMAIN}" ]; then
      print_warn "WS-TLS 节点 ${tag} 使用默认优选域名 ${DEFAULT_CDN_DOMAIN}：仅当该域名已接入本机前置 CDN 时可用，否则请把 cdn_host 设为你自己的域名。"
    fi
    printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s' \
      "$uuid" "$(wrap_host "$(url_encode "$preferred_domain")")" "$port" \
      "$(url_encode "$host_domain")" "$(url_encode "$host_domain")" "$(url_encode "$ws_path")"
    if [ "$cert_mode" = "self-signed" ]; then
      printf '&allowInsecure=1'
    fi
    printf '#%s' "$(url_encode "$name")"
    ;;
  anytls)
    password="$(secret_value "$tag" "password")"
    tls_server="$(url_encode "$(node_value "$tag" "tls_server")")"
    cert_mode="$(node_value "$tag" "certificate_mode")"
    printf 'anytls://%s@%s:%s?security=tls&sni=%s' \
      "$(url_encode "$password")" "$host" "$port" "$tls_server"
    if [ "$cert_mode" = "self-signed" ]; then
      printf '&allowInsecure=1'
    fi
    printf '#%s' "$(url_encode "$name")"
    ;;
  vless-argo)
    uuid="$(secret_value "$tag" "uuid")"
    ws_path="$(node_value "$tag" "ws_path")"
    preferred_domain="$(node_value "$tag" "preferred_domain")"
    endpoint_domain="$(node_value "$tag" "endpoint_domain")"
    if [ -z "${endpoint_domain}" ] || [ "${endpoint_domain}" = "待分配.example.com" ]; then
      print_warn "节点 ${tag} 的 Argo 域名尚未分配（隧道可能未连上），链接暂不可用；稍后重试 sbm list。"
      return 0
    fi
    printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s#%s' \
      "$uuid" "$(wrap_host "$(url_encode "$preferred_domain")")" \
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
      printf '&insecure=1'
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
