#!/usr/bin/env bash
set -eEuo pipefail

umask 077

PROJECT_NAME="Singbox 管理器"
SCRIPT_VERSION="0.2.11"
REPO_OWNER="hynize"
REPO_NAME="singbox-manager"

INSTALL_BIN="${INSTALL_BIN:-/usr/local/bin/sbm}"
LIB_DIR="${LIB_DIR:-/usr/local/lib/singbox-manager}"
BASE_DIR="${BASE_DIR:-/usr/local/etc/singbox-manager}"
WATCHDOG_TARGET="${BASE_DIR}/watchdog.sh"
UPSTREAM_ENV="${LIB_DIR}/upstream.env"
PID_FILE="${BASE_DIR}/runtime/sing-box.pid"

SINGBOX_BIN="${SINGBOX_BIN:-/usr/local/bin/sing-box}"
CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-/usr/local/bin/cloudflared}"
SERVICE_NAME="singbox-manager"
WATCHDOG_SERVICE_NAME="singbox-manager-watchdog"
WATCHDOG_TIMER_NAME="singbox-manager-watchdog.timer"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SYSTEMD_WATCHDOG_SERVICE_FILE="/etc/systemd/system/${WATCHDOG_SERVICE_NAME}.service"
SYSTEMD_WATCHDOG_TIMER_FILE="/etc/systemd/system/${WATCHDOG_TIMER_NAME}"
OPENRC_SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"

DEFAULT_CDN_DOMAIN="saas.sin.fan"
DEFAULT_REALITY_SERVER="www.apple.com"
DEFAULT_TLS_SERVER="www.apple.com"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT=""
if [ -f "${SCRIPT_DIR}/lib/common.sh" ]; then
  SOURCE_ROOT="${SCRIPT_DIR}"
  # shellcheck source=lib/common.sh
  . "${SCRIPT_DIR}/lib/common.sh"
elif [ -f "${LIB_DIR}/common.sh" ]; then
  # shellcheck source=/usr/local/lib/singbox-manager/common.sh
  . "${LIB_DIR}/common.sh"
else
  echo "未找到 common.sh。" >&2
  exit 1
fi

if [ -n "${SOURCE_ROOT}" ] && [ -f "${SOURCE_ROOT}/metadata/upstream.env" ]; then
  # shellcheck source=metadata/upstream.env
  . "${SOURCE_ROOT}/metadata/upstream.env"
elif [ -f "${UPSTREAM_ENV}" ]; then
  # shellcheck source=/usr/local/lib/singbox-manager/upstream.env
  . "${UPSTREAM_ENV}"
else
  fatal "未找到 upstream.env。"
fi

setup_common_traps

has_systemd=false
has_openrc=false

detect_systemd() {
  has_systemd=false
  has_openrc=false

  if command_exists systemctl && [ -d /run/systemd/system ]; then
    has_systemd=true
  elif command_exists rc-service && [ -x /sbin/openrc-run ]; then
    has_openrc=true
  fi
}

normalize_input() {
  local value="$1"
  printf '%s' "$value" |
    tr -d '\000-\037\177' |
    sed -e 's/\r//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

prompt_with_default() {
  local prompt="$1"
  local default="$2"
  local value
  read -r -p "${prompt} [${default}]: " value
  value="$(normalize_input "${value:-$default}")"
  printf '%s' "${value:-$default}"
}

prompt_nonempty() {
  local prompt="$1"
  local value=""
  while [ -z "$value" ]; do
    read -r -p "${prompt}: " value
    value="$(normalize_input "$value")"
  done
  printf '%s' "$value"
}

prompt_optional_value() {
  local prompt="$1"
  local value
  read -r -p "${prompt}: " value
  normalize_input "$value"
}

confirm_yes() {
  local prompt="$1"
  local answer
  read -r -p "${prompt} [y/N]: " answer
  answer="$(normalize_input "$answer")"
  [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss]|是)$ ]]
}

prompt_choice() {
  local prompt="$1"
  local default="$2"
  local value
  read -r -p "${prompt} [${default}]: " value
  value="$(normalize_input "${value:-$default}")"
  printf '%s' "${value,,}"
}

prompt_positive_integer() {
  local prompt="$1"
  local default="$2"
  local value
  while true; do
    value="$(prompt_with_default "${prompt}" "${default}")"
    if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -gt 0 ]; then
      printf '%s' "$value"
      return 0
    fi
    print_warn "${prompt} 必须是大于 0 的整数。"
  done
}

detect_arch() {
  case "$(uname -m)" in
  x86_64 | amd64) printf 'amd64' ;;
  aarch64 | arm64) printf 'arm64' ;;
  armv7l | armv7) printf 'armv7' ;;
  armv6l | armv6) printf 'armv6' ;;
  *) return 1 ;;
  esac
}

pkg_install() {
  if command_exists apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "$@"
  elif command_exists dnf; then
    dnf install -y "$@"
  elif command_exists yum; then
    yum install -y "$@"
  elif command_exists apk; then
    apk add --no-cache "$@"
  elif command_exists pacman; then
    pacman -Sy --noconfirm "$@"
  elif command_exists zypper; then
    zypper --non-interactive install "$@"
  else
    fatal "暂不支持当前包管理器，请手动安装以下依赖：$*"
  fi
}

ensure_dependencies() {
  local packages=()
  if command_exists apt-get; then
    packages=(ca-certificates curl tar jq openssl procps iproute2 util-linux findutils grep sed gawk coreutils)
  elif command_exists dnf || command_exists yum; then
    packages=(ca-certificates curl tar jq openssl procps-ng iproute util-linux findutils grep sed gawk coreutils)
  elif command_exists apk; then
    packages=(ca-certificates curl tar jq openssl procps iproute2 util-linux findutils grep sed gawk coreutils gcompat)
  elif command_exists pacman; then
    packages=(ca-certificates curl tar jq openssl procps-ng iproute2 util-linux findutils grep sed gawk coreutils)
  elif command_exists zypper; then
    packages=(ca-certificates curl tar jq openssl procps iproute2 util-linux findutils grep sed gawk coreutils)
  fi

  pkg_install "${packages[@]}"
  verify_runtime_prereqs
}

verify_runtime_prereqs() {
  local missing=()
  local required=(
    curl tar jq openssl awk sed grep find head mktemp install nohup tr hostname
  )

  local proc_tools=("kill" "rm" "mv" "chmod" "cat" "cp")
  required+=("${proc_tools[@]}")

  if [ "${has_systemd}" = true ]; then
    required+=("systemctl")
  elif [ "${has_openrc}" = true ]; then
    required+=("rc-service" "rc-update")
  fi

  for cmd in "${required[@]}"; do
    command_exists "$cmd" || missing+=("$cmd")
  done

  if ! command_exists ss && ! command_exists netstat; then
    missing+=("ss/netstat")
  fi

  if [ "${#missing[@]}" -gt 0 ]; then
    fatal "缺少必要命令：${missing[*]}"
  fi
}

ensure_binary_runs() {
  local binary="$1"
  local label="$2"
  shift 2

  if "$binary" "$@" >/dev/null 2>&1; then
    return 0
  fi

  if command_exists apk; then
    print_info "检测到 Alpine，正在安装 gcompat 兼容层"
    apk add --no-cache gcompat >/dev/null 2>&1
  fi

  "$binary" "$@" >/dev/null 2>&1 || fatal "${label} 已安装，但当前系统无法运行。"
}

sync_project_assets_from_source() {
  if [ -z "${SOURCE_ROOT}" ]; then
    return 0
  fi

  init_storage
  install -d -m 700 "${LIB_DIR}" "${BASE_DIR}"
  install -m 0755 "${SOURCE_ROOT}/sb.sh" "${INSTALL_BIN}"
  install -m 0644 "${SOURCE_ROOT}/lib/common.sh" "${LIB_DIR}/common.sh"
  install -m 0644 "${SOURCE_ROOT}/metadata/upstream.env" "${UPSTREAM_ENV}"
  install -m 0755 "${SOURCE_ROOT}/scripts/watchdog.sh" "${WATCHDOG_TARGET}"
  sanitize_permissions
}

install_release_bundle() {
  local tag="$1"
  local bundle_url checksums_url bundle_name tmpdir bundle_file checksums_file expected root_dir

  tmpdir="$(mktemp -d)"
  bundle_name="singbox-manager-${tag}.tar.gz"
  bundle_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${tag}/${bundle_name}"
  checksums_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${tag}/checksums.txt"
  bundle_file="${tmpdir}/${bundle_name}"
  checksums_file="${tmpdir}/checksums.txt"

  download_file "${checksums_url}" "${checksums_file}"
  download_file "${bundle_url}" "${bundle_file}"

  expected="$(awk -v file="${bundle_name}" '{ sub(/\r$/, "", $2); if ($2 == file) print $1 }' "${checksums_file}")"
  [ -n "${expected}" ] || fatal "未找到 ${bundle_name} 的校验值。"
  verify_sha256 "${bundle_file}" "${expected}"

  tar -xzf "${bundle_file}" -C "${tmpdir}"
  root_dir="$(find "${tmpdir}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  install -d -m 700 "${LIB_DIR}" "${BASE_DIR}"
  install -m 0755 "${root_dir}/sb.sh" "${INSTALL_BIN}"
  install -m 0644 "${root_dir}/lib/common.sh" "${LIB_DIR}/common.sh"
  install -m 0644 "${root_dir}/metadata/upstream.env" "${UPSTREAM_ENV}"
  install -m 0755 "${root_dir}/scripts/watchdog.sh" "${WATCHDOG_TARGET}"
  sanitize_permissions
  rm -rf "${tmpdir}"
}

install_singbox_core() {
  local arch asset url tmpdir archive binary expected
  arch="$(detect_arch)" || fatal "暂不支持当前 CPU 架构：$(uname -m)"
  asset="${SINGBOX_ASSET[$arch]:-}"
  expected="${SINGBOX_SHA256[$arch]:-}"
  [ -n "${asset}" ] || fatal "未配置 ${arch} 对应的 sing-box 安装包。"
  [ -n "${expected}" ] || fatal "未配置 ${arch} 对应的 sing-box 校验值。"

  url="https://github.com/SagerNet/sing-box/releases/download/${SINGBOX_VERSION}/${asset}"
  tmpdir="$(mktemp -d)"
  archive="${tmpdir}/${asset}"
  print_info "正在安装 sing-box ${SINGBOX_VERSION} (${arch})"
  download_file "${url}" "${archive}"
  verify_sha256 "${archive}" "${expected}"
  tar -xzf "${archive}" -C "${tmpdir}"
  binary="$(find "${tmpdir}" -type f -name sing-box | head -n 1)"
  [ -n "${binary}" ] || fatal "安装包中未找到 sing-box 可执行文件。"
  install -m 0755 "${binary}" "${SINGBOX_BIN}"
  ensure_binary_runs "${SINGBOX_BIN}" "sing-box" version
  rm -rf "${tmpdir}"
  print_ok "sing-box 已安装到 ${SINGBOX_BIN}"
}

install_cloudflared_bin() {
  local arch asset url tmpfile expected version
  arch="$(detect_arch)" || fatal "暂不支持当前 CPU 架构：$(uname -m)"
  asset="${CLOUDFLARED_ASSET[$arch]:-}"
  [ -n "${asset}" ] || fatal "未配置 ${arch} 对应的 cloudflared 安装包。"

  version="${CLOUDFLARED_VERSION:-}"
  expected="${CLOUDFLARED_SHA256[$arch]:-}"
  if [ "${CLOUDFLARED_LATEST:-false}" = "true" ]; then
    if version="$(cloudflared_latest_version)"; then
      expected="$(cloudflared_latest_digest "${asset}" || true)"
      print_info "cloudflared 官方最新版本：${version}"
    else
      print_warn "无法从 GitHub API 获取 cloudflared 最新版本，回退到固定版本 ${version:-未知}。"
    fi
  fi
  [ -n "${version}" ] || fatal "未配置 cloudflared 版本。"

  url="https://github.com/cloudflare/cloudflared/releases/download/${version}/${asset}"
  tmpfile="$(mktemp)"
  print_info "正在安装 cloudflared ${version} (${arch})"
  download_file "${url}" "${tmpfile}"
  if [ -n "${expected}" ]; then
    verify_sha256 "${tmpfile}" "${expected}"
  else
    print_warn "未获取到 cloudflared 校验和，已跳过完整性校验。"
  fi
  install -m 0755 "${tmpfile}" "${CLOUDFLARED_BIN}"
  ensure_binary_runs "${CLOUDFLARED_BIN}" "cloudflared" version
  rm -f "${tmpfile}"
  print_ok "cloudflared 已安装到 ${CLOUDFLARED_BIN}"
}

create_systemd_units() {
  cat >"${SYSTEMD_SERVICE_FILE}" <<EOF
[Unit]
Description=Singbox Manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${BASE_DIR}
ExecStartPre=${SINGBOX_BIN} check -c ${CONFIG_FILE}
ExecStart=${SINGBOX_BIN} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=3
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectProc=invisible
ProcSubset=pid
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
ReadWritePaths=${BASE_DIR}

[Install]
WantedBy=multi-user.target
EOF

  cat >"${SYSTEMD_WATCHDOG_SERVICE_FILE}" <<EOF
[Unit]
Description=Singbox Manager Watchdog
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${WATCHDOG_TARGET}
KillMode=process
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectProc=invisible
ProcSubset=pid
ReadWritePaths=${BASE_DIR}
EOF

  cat >"${SYSTEMD_WATCHDOG_TIMER_FILE}" <<EOF
[Unit]
Description=Run Singbox Manager Watchdog Every Minute

[Timer]
OnBootSec=90
OnUnitActiveSec=60
Unit=${WATCHDOG_SERVICE_NAME}.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl enable --now "${WATCHDOG_TIMER_NAME}" >/dev/null 2>&1 || true
}

create_openrc_units() {
  cat >"${OPENRC_SERVICE_FILE}" <<EOF
#!/sbin/openrc-run

name="${SERVICE_NAME}"
description="Singbox Manager"
command="${SINGBOX_BIN}"
command_args="run -c ${CONFIG_FILE}"
command_background=true
pidfile="${PID_FILE}"

depend() {
  need net
}

start_pre() {
  ${SINGBOX_BIN} check -c ${CONFIG_FILE} >/dev/null
}
EOF

  chmod 0755 "${OPENRC_SERVICE_FILE}"
  rc-update add "${SERVICE_NAME}" default >/dev/null 2>&1 || true

  if command_exists rc-service && [ -x /etc/init.d/crond ]; then
    rc-update add crond default >/dev/null 2>&1 || true
    rc-service crond start >/dev/null 2>&1 || true
  fi
}

create_cron_watchdog() {
  if ! command_exists crontab; then
    print_warn "未找到 crontab，已跳过 watchdog 的 cron 创建。"
    return 0
  fi

  (
    crontab -l 2>/dev/null | grep -Fv "${WATCHDOG_TARGET}" | grep -Fv "no crontab for" || true
    echo "* * * * * ${WATCHDOG_TARGET} >/dev/null 2>&1"
  ) | crontab -
}

service_state() {
  detect_systemd
  if [ "${has_systemd}" = true ]; then
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
      printf '运行中'
    else
      printf '已停止'
    fi
    return 0
  fi

  if [ "${has_openrc}" = true ]; then
    if rc-service "${SERVICE_NAME}" status >/dev/null 2>&1; then
      printf '运行中'
    else
      printf '已停止'
    fi
    return 0
  fi

  local pid
  pid="$(read_pid_file "${PID_FILE}" 2>/dev/null || true)"
  if [ -n "${pid}" ] && kill -0 "${pid}" >/dev/null 2>&1; then
    printf '运行中'
  else
    printf '已停止'
  fi
}

stop_service() {
  detect_systemd
  if [ "${has_systemd}" = true ]; then
    systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
  elif [ "${has_openrc}" = true ]; then
    rc-service "${SERVICE_NAME}" stop >/dev/null 2>&1 || true
    kill_pid_file "${PID_FILE}"
  else
    kill_pid_file "${PID_FILE}"
  fi
}

start_service() {
  detect_systemd
  [ -x "${SINGBOX_BIN}" ] || fatal "尚未安装 sing-box。"
  rotate_log_file "${BASE_DIR}/logs/sing-box.log" || true
  "${SINGBOX_BIN}" check -c "${CONFIG_FILE}" >/dev/null

  if [ "${has_systemd}" = true ]; then
    systemctl daemon-reload
    systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || systemctl start "${SERVICE_NAME}" >/dev/null 2>&1
    systemctl enable --now "${WATCHDOG_TIMER_NAME}" >/dev/null 2>&1 || true
  elif [ "${has_openrc}" = true ]; then
    stop_service
    rc-service "${SERVICE_NAME}" restart >/dev/null 2>&1 || rc-service "${SERVICE_NAME}" start >/dev/null 2>&1
  else
    stop_service
    nohup "${SINGBOX_BIN}" run -c "${CONFIG_FILE}" >>"${BASE_DIR}/logs/sing-box.log" 2>&1 &
    write_pid_file "${PID_FILE}" "$!"
  fi

  print_ok "服务状态：$(service_state)"
}

install_core() {
  detect_systemd
  acquire_lock
  ensure_dependencies
  init_storage
  sync_project_assets_from_source
  install_singbox_core
  install_cloudflared_bin
  render_config
  if [ "${has_systemd}" = true ]; then
    create_systemd_units
  elif [ "${has_openrc}" = true ]; then
    create_openrc_units
    create_cron_watchdog
  else
    create_cron_watchdog
  fi
  start_service
  restart_all_argo_nodes
  sanitize_permissions
  release_lock
}

ensure_singbox_ready() {
  init_storage
  if [ ! -x "${SINGBOX_BIN}" ]; then
    print_info "检测到 sing-box 尚未安装，开始自动安装。"
    install_core
  fi
}

metadata_has_port() {
  local port="$1"
  jq -e --argjson port "$port" 'to_entries | any(.value.port == $port)' "${NODES_FILE}" >/dev/null 2>&1
}

system_has_port() {
  local port="$1"
  if command_exists ss; then
    ss -ltnuH 2>/dev/null | awk -v port="$port" '
      { addr = $5; sub(/.*:/, "", addr); if (addr == port) found = 1 }
      END { exit found ? 0 : 1 }
    '
  elif command_exists netstat; then
    netstat -lntup 2>/dev/null | awk -v port="$port" '
      $1 ~ /^(tcp|tcp6|udp|udp6)$/ {
        addr = $4; sub(/.*:/, "", addr); if (addr == port) found = 1
      }
      END { exit found ? 0 : 1 }'
  else
    return 1
  fi
}

port_available() {
  local port="$1"
  if metadata_has_port "$port"; then
    return 1
  fi
  if system_has_port "$port"; then
    return 1
  fi
  return 0
}

prompt_port() {
  local default="$1"
  local port
  while true; do
    port="$(prompt_with_default "端口" "$default")"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
      print_warn "端口无效：${port}"
      continue
    fi
    if ! port_available "$port"; then
      print_warn "端口 ${port} 已被占用。"
      continue
    fi
    printf '%s' "$port"
    return 0
  done
}

managed_cert_path() {
  local tag="$1"
  local path="$2"
  [ "${path%/*}" = "${CERT_DIR}" ] || return 1
  case "$path" in
  "${CERT_DIR}/${tag}."*/*) return 1 ;;
  "${CERT_DIR}/${tag}."*) return 0 ;;
  *) return 1 ;;
  esac
}

import_custom_certificate_bundle() {
  local tag="$1"
  local cert_path="$2"
  local key_path="$3"
  local cert_file="${CERT_DIR}/${tag}.custom.crt"
  local key_file="${CERT_DIR}/${tag}.custom.key"
  local cert_copied=false

  if [ "$cert_path" != "$cert_file" ]; then
    cp "$cert_path" "$cert_file" || return 1
    cert_copied=true
  fi
  if [ "$key_path" != "$key_file" ]; then
    cp "$key_path" "$key_file" || {
      if [ "$cert_copied" = true ]; then
        rm -f "$cert_file"
      fi
      return 1
    }
  fi
  chmod 600 "$cert_file" "$key_file"
  printf '%s|%s' "$cert_file" "$key_file"
}

remove_node_certificates() {
  local tag="$1"
  local cert_file="${2:-}"
  local key_file="${3:-}"

  if [ -n "$cert_file" ] && [ -f "$cert_file" ] && managed_cert_path "$tag" "$cert_file"; then
    rm -f "$cert_file"
  fi
  if [ -n "$key_file" ] && [ -f "$key_file" ] && managed_cert_path "$tag" "$key_file"; then
    rm -f "$key_file"
  fi
}

migrate_custom_certificate_bundle() {
  local tag="$1"
  local cert_mode cert_file key_file pair

  cert_mode="$(node_value "$tag" "certificate_mode")"
  [ "$cert_mode" = "custom" ] || return 0

  cert_file="$(node_value "$tag" "certificate_path")"
  key_file="$(node_value "$tag" "key_path")"
  if managed_cert_path "$tag" "$cert_file" && managed_cert_path "$tag" "$key_file"; then
    return 0
  fi
  if [ ! -r "$cert_file" ] || [ ! -r "$key_file" ]; then
    print_err "自定义证书不可读取，无法导入托管目录：${tag}"
    return 1
  fi

  pair="$(import_custom_certificate_bundle "$tag" "$cert_file" "$key_file")" || return 1
  json_set_field "${NODES_FILE}" "$tag" "certificate_path" "${pair%|*}" || return 1
  json_set_field "${NODES_FILE}" "$tag" "key_path" "${pair#*|}" || return 1
}

migrate_custom_certificates() {
  local tags tag
  if ! tags="$(iter_node_tags)"; then
    print_err "读取节点列表失败。"
    return 1
  fi
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    migrate_custom_certificate_bundle "$tag" || return 1
  done <<<"$tags"
}

cleanup_argo_pid() {
  local pid_file="$1"
  kill_pid_file "$pid_file"
}

prompt_certificate_bundle() {
  local tag="$1"
  local default_domain="$2"
  local mode cert_path key_path pair

  while true; do
    mode="$(prompt_choice "证书模式 (self-signed/custom)" "self-signed")"
    case "$mode" in
    self-signed | self | quick)
      pair="$(ensure_tls_material "$tag" "$default_domain")"
      printf 'self-signed|%s|%s' "${pair%|*}" "${pair#*|}"
      return 0
      ;;
    custom)
      cert_path="$(prompt_nonempty "证书路径")"
      key_path="$(prompt_nonempty "私钥路径")"
      [ -r "$cert_path" ] || {
        print_warn "证书不可读取：${cert_path}"
        continue
      }
      [ -r "$key_path" ] || {
        print_warn "私钥不可读取：${key_path}"
        continue
      }
      if ! pair="$(import_custom_certificate_bundle "$tag" "$cert_path" "$key_path")"; then
        print_warn "导入自定义证书失败，请检查路径和权限。"
        continue
      fi
      printf 'custom|%s|%s' "${pair%|*}" "${pair#*|}"
      return 0
      ;;
    *)
      print_warn "请输入 self-signed 或 custom。"
      ;;
    esac
  done
}

rollback_new_node() {
  local tag="$1"
  local cert_file="${2:-}"
  local key_file="${3:-}"
  delete_node_records "$tag" || true
  remove_node_certificates "$tag" "$cert_file" "$key_file"
  render_config || true
  start_service || true
}

save_node_bundle() {
  local tag="$1"
  local node_json="$2"
  local secret_json="$3"
  json_set_record "${NODES_FILE}" "$tag" "$node_json"
  json_set_record "${SECRETS_FILE}" "$tag" "$secret_json"
}

render_config() {
  local inbounds_json tmp tags
  migrate_custom_certificates || return 1
  if ! tags="$(iter_node_tags)"; then
    print_err "读取节点列表失败。"
    return 1
  fi
  if ! inbounds_json="$(
    while IFS= read -r tag; do
      [ -n "${tag}" ] || continue
      render_inbound_for_tag "${tag}" || exit 1
    done <<<"$tags"
  )"; then
    print_err "生成 sing-box 入站配置失败。"
    return 1
  fi

  if [ -n "${inbounds_json}" ]; then
    if ! inbounds_json="$(printf '%s\n' "${inbounds_json}" | jq -s '.')"; then
      print_err "合并 sing-box 入站配置失败。"
      return 1
    fi
  else
    inbounds_json='[]'
  fi

  tmp="$(mktemp "${BASE_DIR}/.config.XXXXXX")"
  if ! jq -n --arg log_path "${BASE_DIR}/logs/sing-box.log" --argjson inbounds "${inbounds_json}" '{
    log: {
      level: "info",
      timestamp: true,
      output: $log_path
    },
    inbounds: $inbounds,
    outbounds: [
      { type: "direct", tag: "direct" }
    ],
    route: {
      final: "direct",
      auto_detect_interface: true
    }
  }' >"${tmp}"; then
    rm -f "${tmp}"
    print_err "写入 sing-box 配置失败。"
    return 1
  fi
  if ! chmod 600 "${tmp}" || ! mv "${tmp}" "${CONFIG_FILE}"; then
    rm -f "${tmp}"
    print_err "保存 sing-box 配置失败。"
    return 1
  fi
}

render_inbound_for_tag() {
  local tag="$1"
  local protocol name port uuid password cert_file key_file ws_path reality_server

  protocol="$(node_value "$tag" "protocol")"
  name="$(node_value "$tag" "name")"
  port="$(node_value "$tag" "port")"

  case "$protocol" in
  vless-reality)
    uuid="$(secret_value "$tag" "uuid")"
    reality_server="$(node_value "$tag" "reality_server")"
    jq -n \
      --arg tag "$tag" \
      --arg name "$name" \
      --arg uuid "$uuid" \
      --arg server "$reality_server" \
      --arg private_key "$(secret_value "$tag" "private_key")" \
      --arg short_id "$(node_value "$tag" "short_id")" \
      --argjson port "$port" '{
          type: "vless",
          tag: $tag,
          listen: "::",
          listen_port: $port,
          users: [{ name: $name, uuid: $uuid, flow: "xtls-rprx-vision" }],
          tls: {
            enabled: true,
            server_name: $server,
            reality: {
              enabled: true,
              handshake: { server: $server, server_port: 443 },
              private_key: $private_key,
              short_id: [$short_id]
            }
          }
        }'
    ;;
  vless-ws-tls)
    uuid="$(secret_value "$tag" "uuid")"
    ws_path="$(node_value "$tag" "ws_path")"
    cert_file="$(node_value "$tag" "certificate_path")"
    key_file="$(node_value "$tag" "key_path")"
    jq -n \
      --arg tag "$tag" \
      --arg name "$name" \
      --arg uuid "$uuid" \
      --arg ws_path "$ws_path" \
      --arg cert_file "$cert_file" \
      --arg key_file "$key_file" \
      --argjson port "$port" '{
          type: "vless",
          tag: $tag,
          listen: "::",
          listen_port: $port,
          users: [{ name: $name, uuid: $uuid }],
          tls: {
            enabled: true,
            certificate_path: $cert_file,
            key_path: $key_file
          },
          transport: { type: "ws", path: $ws_path }
        }'
    ;;
  anytls)
    password="$(secret_value "$tag" "password")"
    cert_file="$(node_value "$tag" "certificate_path")"
    key_file="$(node_value "$tag" "key_path")"
    jq -n \
      --arg tag "$tag" \
      --arg name "$name" \
      --arg password "$password" \
      --arg cert_file "$cert_file" \
      --arg key_file "$key_file" \
      --argjson port "$port" '{
          type: "anytls",
          tag: $tag,
          listen: "::",
          listen_port: $port,
          users: [{ name: $name, password: $password }],
          tls: {
            enabled: true,
            certificate_path: $cert_file,
            key_path: $key_file
          }
        }'
    ;;
  vless-argo)
    uuid="$(secret_value "$tag" "uuid")"
    ws_path="$(node_value "$tag" "ws_path")"
    jq -n \
      --arg tag "$tag" \
      --arg name "$name" \
      --arg uuid "$uuid" \
      --arg ws_path "$ws_path" \
      --argjson port "$port" '{
          type: "vless",
          tag: $tag,
          listen: "127.0.0.1",
          listen_port: $port,
          users: [{ name: $name, uuid: $uuid }],
          transport: { type: "ws", path: $ws_path }
        }'
    ;;
  tuic-v5)
    uuid="$(secret_value "$tag" "uuid")"
    password="$(secret_value "$tag" "password")"
    cert_file="$(node_value "$tag" "certificate_path")"
    key_file="$(node_value "$tag" "key_path")"
    jq -n \
      --arg tag "$tag" \
      --arg name "$name" \
      --arg uuid "$uuid" \
      --arg password "$password" \
      --arg cert_file "$cert_file" \
      --arg key_file "$key_file" \
      --argjson port "$port" '{
          type: "tuic",
          tag: $tag,
          listen: "::",
          listen_port: $port,
          users: [{ name: $name, uuid: $uuid, password: $password }],
          congestion_control: "bbr",
          zero_rtt_handshake: false,
          heartbeat: "10s",
          tls: {
            enabled: true,
            alpn: ["h3"],
            certificate_path: $cert_file,
            key_path: $key_file
          }
        }'
    ;;
  hy2)
    password="$(secret_value "$tag" "password")"
    cert_file="$(node_value "$tag" "certificate_path")"
    key_file="$(node_value "$tag" "key_path")"
    local up_mbps down_mbps
    up_mbps="$(node_value "$tag" "up_mbps")"
    down_mbps="$(node_value "$tag" "down_mbps")"
    jq -n \
      --arg tag "$tag" \
      --arg name "$name" \
      --arg password "$password" \
      --arg cert_file "$cert_file" \
      --arg key_file "$key_file" \
      --argjson up_mbps "${up_mbps:-200}" \
      --argjson down_mbps "${down_mbps:-200}" \
      --argjson port "$port" '{
          type: "hysteria2",
          tag: $tag,
          listen: "::",
          listen_port: $port,
          users: [{ name: $name, password: $password }],
          up_mbps: $up_mbps,
          down_mbps: $down_mbps,
          tls: {
            enabled: true,
            alpn: ["h3"],
            certificate_path: $cert_file,
            key_path: $key_file
          }
        }'
    ;;
  socks5)
    jq -n \
      --arg tag "$tag" \
      --arg username "$(node_value "$tag" "username")" \
      --arg password "$(secret_value "$tag" "password")" \
      --argjson port "$port" '{
          type: "socks",
          tag: $tag,
          listen: "::",
          listen_port: $port,
          users: [{ username: $username, password: $password }]
        }'
    ;;
  *)
    print_err "不支持的节点协议：${protocol}"
    return 1
    ;;
  esac
}

stop_argo_node() {
  local tag="$1"
  kill_pid_file "${BASE_DIR}/runtime/${tag}.pid"
}

start_argo_node() {
  local tag="$1"
  local mode port token log_file pid_file domain edge_ip

  [ -x "${CLOUDFLARED_BIN}" ] || install_cloudflared_bin
  mode="$(node_value "$tag" "argo_mode")"
  port="$(node_value "$tag" "port")"
  log_file="${BASE_DIR}/logs/${tag}.cloudflared.log"
  pid_file="${BASE_DIR}/runtime/${tag}.pid"

  stop_argo_node "$tag"
  : >"${log_file}"
  chmod 600 "${log_file}"

  edge_ip="$(argo_edge_ip_version)"

  if [ "${mode}" = "token" ]; then
    token="$(secret_value "$tag" "argo_token")"
    nohup "${CLOUDFLARED_BIN}" tunnel --no-autoupdate --edge-ip-version "${edge_ip}" run --token "${token}" \
      >"${log_file}" 2>&1 &
    write_pid_file "${pid_file}" "$!"
    return 0
  fi

  nohup "${CLOUDFLARED_BIN}" tunnel --no-autoupdate --edge-ip-version "${edge_ip}" --url "http://127.0.0.1:${port}" \
    >"${log_file}" 2>&1 &
  write_pid_file "${pid_file}" "$!"

  if domain="$(wait_for_trycloudflare_domain "${log_file}" 60 2)"; then
    if ! json_set_field "${NODES_FILE}" "${tag}" "endpoint_domain" "${domain}"; then
      cleanup_argo_pid "${pid_file}"
      return 1
    fi
  else
    cleanup_argo_pid "${pid_file}"
    print_err "等待 ${tag} 的临时 Argo 域名超时。"
    return 1
  fi
}

restart_all_argo_nodes() {
  local tag
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    if [ "$(node_value "$tag" "protocol")" = "vless-argo" ]; then
      start_argo_node "$tag"
    fi
  done < <(iter_node_tags)
}

add_vless_reality() {
  local tag port name uuid reality_server key_output private_key public_key short_id node_json secret_json
  ensure_singbox_ready
  acquire_lock
  tag="$(generate_tag "vless-reality")"
  port="$(prompt_port 443)"
  name="$(prompt_with_default "节点名称" "VLESS-Reality")"
  uuid="$(prompt_optional_value "UUID（留空自动生成）")"
  uuid="${uuid:-$(generate_uuid)}"
  reality_server="$(prompt_with_default "Reality 域名" "${DEFAULT_REALITY_SERVER}")"

  key_output="$("${SINGBOX_BIN}" generate reality-keypair)"
  private_key="$(printf '%s\n' "$key_output" | sed -n 's/^PrivateKey:[[:space:]]*//p' | head -n 1)"
  public_key="$(printf '%s\n' "$key_output" | sed -n 's/^PublicKey:[[:space:]]*//p' | head -n 1)"
  [ -n "$private_key" ] || fatal "无法解析 Reality 私钥。"
  [ -n "$public_key" ] || fatal "无法解析 Reality 公钥。"
  short_id="$(generate_hex 4)"

  node_json="$(jq -n \
    --arg protocol "vless-reality" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg reality_server "$reality_server" \
    --arg public_key "$public_key" \
    --arg short_id "$short_id" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      reality_server: $reality_server,
      public_key: $public_key,
      short_id: $short_id
    }')"

  secret_json="$(jq -n \
    --arg uuid "$uuid" \
    --arg private_key "$private_key" '{ uuid: $uuid, private_key: $private_key }')"

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! start_service; then
    rollback_new_node "$tag"
    release_lock
    fatal "添加节点失败：${name}"
  fi

  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}

add_vless_ws_tls() {
  local tag port name uuid preferred_domain host_domain ws_path cert_bundle cert_mode cert_file key_file node_json secret_json
  ensure_singbox_ready
  acquire_lock
  tag="$(generate_tag "vless-ws-tls")"
  port="$(prompt_port 8443)"
  name="$(prompt_with_default "节点名称" "VLESS-WS-TLS")"
  uuid="$(prompt_optional_value "UUID（留空自动生成）")"
  uuid="${uuid:-$(generate_uuid)}"
  preferred_domain="$(prompt_with_default "优选域名" "${DEFAULT_CDN_DOMAIN}")"
  host_domain="$(prompt_with_default "Host/SNI 域名" "${DEFAULT_TLS_SERVER}")"
  ws_path="$(prompt_with_default "WebSocket 路径" "$(random_ws_path)")"
  cert_bundle="$(prompt_certificate_bundle "$tag" "$host_domain")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  node_json="$(jq -n \
    --arg protocol "vless-ws-tls" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg preferred_domain "$preferred_domain" \
    --arg host_domain "$host_domain" \
    --arg ws_path "$ws_path" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      preferred_domain: $preferred_domain,
      host_domain: $host_domain,
      ws_path: $ws_path,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')"

  secret_json="$(jq -n --arg uuid "$uuid" '{ uuid: $uuid }')"

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! start_service; then
    rollback_new_node "$tag" "$cert_file" "$key_file"
    release_lock
    fatal "添加节点失败：${name}"
  fi

  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}

add_anytls() {
  local tag port name password tls_server cert_bundle cert_mode cert_file key_file node_json secret_json
  ensure_singbox_ready
  acquire_lock
  tag="$(generate_tag "anytls")"
  port="$(prompt_port 5443)"
  name="$(prompt_with_default "节点名称" "AnyTLS")"
  password="$(prompt_optional_value "密码（留空自动生成）")"
  password="${password:-$(generate_hex 8)}"
  tls_server="$(prompt_with_default "SNI 域名" "${DEFAULT_TLS_SERVER}")"
  cert_bundle="$(prompt_certificate_bundle "$tag" "$tls_server")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  node_json="$(jq -n \
    --arg protocol "anytls" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg tls_server "$tls_server" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      tls_server: $tls_server,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')"

  secret_json="$(jq -n --arg password "$password" '{ password: $password }')"

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! start_service; then
    rollback_new_node "$tag" "$cert_file" "$key_file"
    release_lock
    fatal "添加节点失败：${name}"
  fi

  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}

add_vless_argo() {
  local tag port name uuid preferred_domain ws_path argo_mode argo_token endpoint_domain node_json secret_json
  ensure_singbox_ready
  acquire_lock
  tag="$(generate_tag "vless-argo")"
  port="$(prompt_port 8001)"
  name="$(prompt_with_default "节点名称" "VLESS-Argo")"
  uuid="$(prompt_optional_value "UUID（留空自动生成）")"
  uuid="${uuid:-$(generate_uuid)}"
  preferred_domain="$(prompt_with_default "优选域名" "${DEFAULT_CDN_DOMAIN}")"
  ws_path="$(prompt_with_default "WebSocket 路径" "$(random_ws_path)")"
  argo_mode="$(prompt_choice "隧道模式 (temp/token)" "temp")"
  if [ "${argo_mode}" = "token" ]; then
    argo_token="$(prompt_nonempty "Cloudflared 隧道 Token")"
    endpoint_domain="$(prompt_nonempty "Argo 回源域名")"
  else
    argo_mode="temp"
    argo_token=""
    endpoint_domain=""
  fi

  node_json="$(jq -n \
    --arg protocol "vless-argo" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg preferred_domain "$preferred_domain" \
    --arg ws_path "$ws_path" \
    --arg argo_mode "$argo_mode" \
    --arg endpoint_domain "$endpoint_domain" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      preferred_domain: $preferred_domain,
      ws_path: $ws_path,
      argo_mode: $argo_mode,
      endpoint_domain: $endpoint_domain
    }')"

  secret_json="$(jq -n \
    --arg uuid "$uuid" \
    --arg argo_token "$argo_token" '{ uuid: $uuid, argo_token: $argo_token }')"

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! start_service || ! start_argo_node "$tag"; then
    rollback_new_node "$tag"
    release_lock
    fatal "添加节点失败：${name}"
  fi

  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}

add_tuic_v5() {
  local tag port name uuid password tls_server cert_bundle cert_mode cert_file key_file node_json secret_json
  ensure_singbox_ready
  acquire_lock
  tag="$(generate_tag "tuic-v5")"
  port="$(prompt_port 10443)"
  name="$(prompt_with_default "节点名称" "TUIC-v5")"
  uuid="$(prompt_optional_value "UUID（留空自动生成）")"
  uuid="${uuid:-$(generate_uuid)}"
  password="$(prompt_optional_value "密码（留空自动生成）")"
  password="${password:-$uuid}"
  tls_server="$(prompt_with_default "SNI 域名" "${DEFAULT_TLS_SERVER}")"
  cert_bundle="$(prompt_certificate_bundle "$tag" "$tls_server")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  node_json="$(jq -n \
    --arg protocol "tuic-v5" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg tls_server "$tls_server" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      tls_server: $tls_server,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')"

  secret_json="$(jq -n --arg uuid "$uuid" --arg password "$password" '{ uuid: $uuid, password: $password }')"

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! start_service; then
    rollback_new_node "$tag" "$cert_file" "$key_file"
    release_lock
    fatal "添加节点失败：${name}"
  fi

  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}

add_hy2() {
  local tag port name password tls_server cert_bundle cert_mode cert_file key_file node_json secret_json up_mbps down_mbps
  ensure_singbox_ready
  acquire_lock
  tag="$(generate_tag "hy2")"
  port="$(prompt_port 11443)"
  name="$(prompt_with_default "节点名称" "Hysteria2")"
  password="$(prompt_optional_value "密码（留空自动生成）")"
  password="${password:-$(generate_hex 8)}"
  tls_server="$(prompt_with_default "SNI 域名" "${DEFAULT_TLS_SERVER}")"
  up_mbps="$(prompt_positive_integer "上行带宽 Mbps" 200)"
  down_mbps="$(prompt_positive_integer "下行带宽 Mbps" 200)"
  cert_bundle="$(prompt_certificate_bundle "$tag" "$tls_server")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  node_json="$(jq -n \
    --arg protocol "hy2" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg tls_server "$tls_server" \
    --argjson up_mbps "$up_mbps" \
    --argjson down_mbps "$down_mbps" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      tls_server: $tls_server,
      up_mbps: $up_mbps,
      down_mbps: $down_mbps,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')"

  secret_json="$(jq -n --arg password "$password" '{ password: $password }')"

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! start_service; then
    rollback_new_node "$tag" "$cert_file" "$key_file"
    release_lock
    fatal "添加节点失败：${name}"
  fi

  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}

add_socks5() {
  local tag port name username password node_json secret_json
  ensure_singbox_ready
  acquire_lock
  tag="$(generate_tag "socks5")"
  port="$(prompt_port 1080)"
  name="$(prompt_with_default "节点名称" "SOCKS5")"
  username="$(prompt_with_default "用户名" "user")"
  password="$(prompt_optional_value "密码（留空自动生成）")"
  password="${password:-$(generate_hex 6)}"

  node_json="$(jq -n \
    --arg protocol "socks5" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg username "$username" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      username: $username
    }')"

  secret_json="$(jq -n --arg password "$password" '{ password: $password }')"

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! start_service; then
    rollback_new_node "$tag"
    release_lock
    fatal "添加节点失败：${name}"
  fi

  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}

# ---------------------------------------------------------------------------
# 环境变量一键安装（rep / ins），配合网页命令生成器使用
# 端口启用协议: vlrt=VLESS-Reality wspt=VLESS-WS-TLS tupt=TUIC anypt=AnyTLS
#               hypt=Hysteria2 socks5pt=SOCKS5 argo=vlpt 启用 VLESS-Argo
# ---------------------------------------------------------------------------

# 注意：局部变量统一加 __env_ 前缀，避免与用户环境变量同名，
# 否则 ${!key} 间接引用会命中局部变量（bash 动态作用域）导致取值错误。
env_var() {
  local __env_key="$1"
  local __env_value="${!__env_key:-}"
  printf '%s' "$(normalize_input "${__env_value}")"
}

env_port() {
  local __env_key="$1"
  local __env_value
  __env_value="$(env_var "$__env_key")"
  if [ -z "$__env_value" ]; then
    return 1
  fi
  if ! [[ "$__env_value" =~ ^[0-9]+$ ]] || [ "$__env_value" -lt 1 ] || [ "$__env_value" -gt 65535 ]; then
    print_warn "环境变量 ${__env_key} 不是有效端口（1-65535）：${__env_value}，已忽略。"
    return 1
  fi
  printf '%s' "$__env_value"
}

auto_has_node_env() {
  local v
  for v in vlrt wspt tupt anypt hypt socks5pt argo; do
    if [ -n "$(env_var "$v")" ]; then
      return 0
    fi
  done
  return 1
}

auto_cert_bundle() {
  local tag="$1"
  local domain="$2"
  local mode cert_path key_path pair

  mode="$(env_var "cert")"
  mode="${mode:-self}"
  if [ "${mode}" = "custom" ]; then
    cert_path="$(env_var "cert_path")"
    key_path="$(env_var "key_path")"
    if [ -n "$cert_path" ] && [ -n "$key_path" ] && pair="$(import_custom_certificate_bundle "$tag" "$cert_path" "$key_path")"; then
      printf 'custom|%s|%s' "${pair%|*}" "${pair#*|}"
      return 0
    fi
    print_warn "自定义证书不可用（缺少 cert_path/key_path 或读取失败），节点 ${tag} 回退自签证书。"
  elif [ "${mode}" != "self" ] && [ "${mode}" != "self-signed" ]; then
    print_warn "未知证书模式 cert=${mode}，节点 ${tag} 使用自签证书。"
  fi
  pair="$(ensure_tls_material "$tag" "$domain")"
  printf 'self-signed|%s|%s' "${pair%|*}" "${pair#*|}"
}

auto_save_node() {
  local tag="$1"
  local node_json="$2"
  local secret_json="$3"
  save_node_bundle "$tag" "$node_json" "$secret_json"
}

auto_add_vless_reality() {
  local port="$1"
  local tag name uuid reality_server key_output private_key public_key short_id node_json secret_json
  tag="$(generate_tag "vless-reality")"
  if [ -n "${ENV_NAME}" ]; then name="${ENV_NAME}-Reality"; else name="VLESS-Reality"; fi
  uuid="${ENV_UUID:-$(generate_uuid)}"
  reality_server="${ENV_VL_SNI:-${DEFAULT_REALITY_SERVER}}"

  if ! key_output="$("${SINGBOX_BIN}" generate reality-keypair)"; then
    print_err "生成 Reality 密钥对失败，跳过 vlrt 节点。"
    return 1
  fi
  private_key="$(printf '%s\n' "$key_output" | sed -n 's/^PrivateKey:[[:space:]]*//p' | head -n 1)"
  public_key="$(printf '%s\n' "$key_output" | sed -n 's/^PublicKey:[[:space:]]*//p' | head -n 1)"
  if [ -z "$private_key" ] || [ -z "$public_key" ]; then
    print_err "无法解析 Reality 密钥对，跳过 vlrt 节点。"
    return 1
  fi
  short_id="$(generate_hex 4)"

  node_json="$(jq -n \
    --arg protocol "vless-reality" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg reality_server "$reality_server" \
    --arg public_key "$public_key" \
    --arg short_id "$short_id" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      reality_server: $reality_server,
      public_key: $public_key,
      short_id: $short_id
    }')"

  secret_json="$(jq -n \
    --arg uuid "$uuid" \
    --arg private_key "$private_key" '{ uuid: $uuid, private_key: $private_key }')"

  auto_save_node "$tag" "$node_json" "$secret_json"
  print_ok "已写入节点：${name} | 端口: ${port}"
}

auto_add_vless_ws_tls() {
  local port="$1"
  local tag name uuid preferred_domain host_domain ws_path cert_bundle cert_mode cert_file key_file node_json secret_json
  tag="$(generate_tag "vless-ws-tls")"
  if [ -n "${ENV_NAME}" ]; then name="${ENV_NAME}-WS-TLS"; else name="VLESS-WS-TLS"; fi
  uuid="${ENV_UUID:-$(generate_uuid)}"
  preferred_domain="${ENV_CDN_HOST:-${DEFAULT_CDN_DOMAIN}}"
  host_domain="${ENV_WS_HOST:-${DEFAULT_TLS_SERVER}}"
  ws_path="${ENV_WS_PATH:-$(random_ws_path)}"
  cert_bundle="$(auto_cert_bundle "$tag" "$host_domain")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  node_json="$(jq -n \
    --arg protocol "vless-ws-tls" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg preferred_domain "$preferred_domain" \
    --arg host_domain "$host_domain" \
    --arg ws_path "$ws_path" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      preferred_domain: $preferred_domain,
      host_domain: $host_domain,
      ws_path: $ws_path,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')"

  secret_json="$(jq -n --arg uuid "$uuid" '{ uuid: $uuid }')"

  auto_save_node "$tag" "$node_json" "$secret_json"
  print_ok "已写入节点：${name} | 端口: ${port}"
}

auto_add_anytls() {
  local port="$1"
  local tag name password tls_server cert_bundle cert_mode cert_file key_file node_json secret_json
  tag="$(generate_tag "anytls")"
  if [ -n "${ENV_NAME}" ]; then name="${ENV_NAME}-AnyTLS"; else name="AnyTLS"; fi
  password="${ENV_PASSWD:-$(generate_hex 8)}"
  tls_server="${ENV_ANY_SNI:-${DEFAULT_TLS_SERVER}}"
  cert_bundle="$(auto_cert_bundle "$tag" "$tls_server")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  node_json="$(jq -n \
    --arg protocol "anytls" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg tls_server "$tls_server" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      tls_server: $tls_server,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')"

  secret_json="$(jq -n --arg password "$password" '{ password: $password }')"

  auto_save_node "$tag" "$node_json" "$secret_json"
  print_ok "已写入节点：${name} | 端口: ${port}"
}

auto_argo_requested() {
  local v
  v="$(env_var "argo")"
  case "${v,,}" in
  vlpt | vless | true | 1 | yes) return 0 ;;
  *) return 1 ;;
  esac
}

auto_add_vless_argo() {
  local port="$1"
  local tag name uuid preferred_domain ws_path argo_mode argo_token endpoint_domain node_json secret_json
  tag="$(generate_tag "vless-argo")"
  if [ -n "${ENV_NAME}" ]; then name="${ENV_NAME}-Argo"; else name="VLESS-Argo"; fi
  uuid="${ENV_UUID:-$(generate_uuid)}"
  preferred_domain="${ENV_CDN_HOST:-${DEFAULT_CDN_DOMAIN}}"
  ws_path="${ENV_WS_PATH:-$(random_ws_path)}"
  argo_token="$(env_var "agk")"
  endpoint_domain="$(env_var "agn")"
  if [ -n "$argo_token" ] && [ -n "$endpoint_domain" ]; then
    argo_mode="token"
  else
    if [ -n "$argo_token" ] || [ -n "$endpoint_domain" ]; then
      print_warn "Argo 固定隧道需要同时提供 agn（域名）和 agk（Token），已回退临时隧道。"
    fi
    argo_mode="temp"
    argo_token=""
    endpoint_domain=""
  fi

  node_json="$(jq -n \
    --arg protocol "vless-argo" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg preferred_domain "$preferred_domain" \
    --arg ws_path "$ws_path" \
    --arg argo_mode "$argo_mode" \
    --arg endpoint_domain "$endpoint_domain" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      preferred_domain: $preferred_domain,
      ws_path: $ws_path,
      argo_mode: $argo_mode,
      endpoint_domain: $endpoint_domain
    }')"

  secret_json="$(jq -n \
    --arg uuid "$uuid" \
    --arg argo_token "$argo_token" '{ uuid: $uuid, argo_token: $argo_token }')"

  auto_save_node "$tag" "$node_json" "$secret_json"
  print_ok "已写入节点：${name} | 本地端口: ${port} | 模式: ${argo_mode}"
}

auto_add_tuic_v5() {
  local port="$1"
  local tag name uuid password tls_server cert_bundle cert_mode cert_file key_file node_json secret_json
  tag="$(generate_tag "tuic-v5")"
  if [ -n "${ENV_NAME}" ]; then name="${ENV_NAME}-TUIC"; else name="TUIC-v5"; fi
  uuid="${ENV_UUID:-$(generate_uuid)}"
  password="${ENV_PASSWD:-$uuid}"
  tls_server="${ENV_TU_SNI:-${DEFAULT_TLS_SERVER}}"
  cert_bundle="$(auto_cert_bundle "$tag" "$tls_server")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  node_json="$(jq -n \
    --arg protocol "tuic-v5" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg tls_server "$tls_server" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      tls_server: $tls_server,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')"

  secret_json="$(jq -n --arg uuid "$uuid" --arg password "$password" '{ uuid: $uuid, password: $password }')"

  auto_save_node "$tag" "$node_json" "$secret_json"
  print_ok "已写入节点：${name} | 端口: ${port}"
}

auto_positive_or_default() {
  local __env_key="$1"
  local __env_default="$2"
  local __env_value
  __env_value="$(env_var "$__env_key")"
  if [[ "$__env_value" =~ ^[0-9]+$ ]] && [ "$__env_value" -gt 0 ]; then
    printf '%s' "$__env_value"
  else
    printf '%s' "$__env_default"
  fi
}

auto_add_hy2() {
  local port="$1"
  local tag name password tls_server cert_bundle cert_mode cert_file key_file node_json secret_json
  local __hy_up __hy_down
  tag="$(generate_tag "hy2")"
  if [ -n "${ENV_NAME}" ]; then name="${ENV_NAME}-HY2"; else name="Hysteria2"; fi
  password="${ENV_PASSWD:-$(generate_hex 8)}"
  tls_server="${ENV_HY_SNI:-${DEFAULT_TLS_SERVER}}"
  # 局部名不用 up_mbps/down_mbps，避免遮蔽同名用户环境变量导致读取为空
  __hy_up="$(auto_positive_or_default "up_mbps" 200)"
  __hy_down="$(auto_positive_or_default "down_mbps" 200)"
  cert_bundle="$(auto_cert_bundle "$tag" "$tls_server")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  node_json="$(jq -n \
    --arg protocol "hy2" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg tls_server "$tls_server" \
    --argjson up_mbps "$__hy_up" \
    --argjson down_mbps "$__hy_down" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      tls_server: $tls_server,
      up_mbps: $up_mbps,
      down_mbps: $down_mbps,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')"

  secret_json="$(jq -n --arg password "$password" '{ password: $password }')"

  auto_save_node "$tag" "$node_json" "$secret_json"
  print_ok "已写入节点：${name} | 端口: ${port}"
}

auto_add_socks5() {
  local port="$1"
  local tag name username password node_json secret_json
  tag="$(generate_tag "socks5")"
  if [ -n "${ENV_NAME}" ]; then name="${ENV_NAME}-SOCKS5"; else name="SOCKS5"; fi
  username="${ENV_SOCKS5_USER:-user}"
  password="${ENV_SOCKS5_PASS:-$(generate_hex 6)}"

  node_json="$(jq -n \
    --arg protocol "socks5" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg username "$username" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      username: $username
    }')"

  secret_json="$(jq -n --arg password "$password" '{ password: $password }')"

  auto_save_node "$tag" "$node_json" "$secret_json"
  print_ok "已写入节点：${name} | 端口: ${port}"
}

wipe_records() {
  local tmp
  tmp="$(mktemp "${BASE_DIR}/.nodes.XXXXXX")"
  printf '{}\n' >"${tmp}" && chmod 600 "${tmp}" && mv "${tmp}" "${NODES_FILE}"
  tmp="$(mktemp "${BASE_DIR}/.secrets.XXXXXX")"
  printf '{}\n' >"${tmp}" && chmod 600 "${tmp}" && mv "${tmp}" "${SECRETS_FILE}"
}

delete_all_nodes() {
  local tag
  init_storage
  acquire_lock
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    stop_argo_node "${tag}"
  done < <(iter_node_tags)
  wipe_records
  render_config
  start_service
  sanitize_permissions
  release_lock
  print_ok "已删除全部节点并重启服务。"
}

auto_try_port() {
  local port="$1"
  local label="$2"
  if ! port_available "$port"; then
    print_warn "端口 ${port} 已被占用，跳过 ${label} 节点。"
    return 1
  fi
  return 0
}

auto_install() {
  local action="$1"
  local tag port added=0 failed=0
  local ENV_NAME ENV_UUID ENV_PASSWD
  local ENV_VL_SNI ENV_TU_SNI ENV_ANY_SNI ENV_HY_SNI ENV_WS_HOST ENV_WS_PATH ENV_CDN_HOST
  local ENV_SOCKS5_USER ENV_SOCKS5_PASS

  detect_systemd
  init_storage

  if ! auto_has_node_env; then
    print_err "未检测到任何节点环境变量（vlrt / wspt / tupt / anypt / hypt / socks5pt / argo），放弃安装。"
    print_info "示例：vlrt=2083 hypt=2082 name='HK' sbm ${action}"
    exit 1
  fi

  ensure_singbox_ready
  acquire_lock

  if [ "${action}" = "rep" ]; then
    while IFS= read -r tag; do
      [ -n "${tag}" ] || continue
      stop_argo_node "${tag}"
    done < <(iter_node_tags)
    stop_service || true
    wipe_records
    print_info "已清空原有节点，按环境变量重建。"
  fi

  ENV_NAME="$(env_var "name")"
  ENV_UUID="$(env_var "uuid")"
  ENV_PASSWD="$(env_var "passwd")"
  ENV_VL_SNI="$(env_var "vl_sni")"
  ENV_TU_SNI="$(env_var "tu_sni")"
  ENV_ANY_SNI="$(env_var "any_sni")"
  ENV_HY_SNI="$(env_var "hy_sni")"
  ENV_WS_HOST="$(env_var "ws_host")"
  ENV_WS_PATH="$(env_var "ws_path")"
  ENV_CDN_HOST="$(env_var "cdn_host")"
  ENV_SOCKS5_USER="$(env_var "socks5_username")"
  ENV_SOCKS5_PASS="$(env_var "socks5_password")"

  if port="$(env_port "vlrt")" && auto_try_port "$port" "VLESS-Reality"; then
    auto_add_vless_reality "$port" && added=$((added + 1)) || failed=$((failed + 1))
  fi
  if port="$(env_port "wspt")" && auto_try_port "$port" "VLESS-WS-TLS"; then
    auto_add_vless_ws_tls "$port" && added=$((added + 1)) || failed=$((failed + 1))
  fi
  if port="$(env_port "anypt")" && auto_try_port "$port" "AnyTLS"; then
    auto_add_anytls "$port" && added=$((added + 1)) || failed=$((failed + 1))
  fi
  if auto_argo_requested; then
    if port="$(env_port "argo_pt")"; then
      :
    else
      port=8001
    fi
    if auto_try_port "$port" "VLESS-Argo"; then
      auto_add_vless_argo "$port" && added=$((added + 1)) || failed=$((failed + 1))
    fi
  fi
  if port="$(env_port "tupt")" && auto_try_port "$port" "TUIC-v5"; then
    auto_add_tuic_v5 "$port" && added=$((added + 1)) || failed=$((failed + 1))
  fi
  if port="$(env_port "hypt")" && auto_try_port "$port" "Hysteria2"; then
    auto_add_hy2 "$port" && added=$((added + 1)) || failed=$((failed + 1))
  fi
  if port="$(env_port "socks5pt")" && auto_try_port "$port" "SOCKS5"; then
    auto_add_socks5 "$port" && added=$((added + 1)) || failed=$((failed + 1))
  fi

  if [ "${added}" -eq 0 ]; then
    if [ "${action}" = "rep" ]; then
      render_config || true
      start_service || true
    fi
    release_lock
    print_err "没有成功写入任何节点（added=0, failed=${failed}）。"
    exit 1
  fi

  render_config
  start_service
  restart_all_argo_nodes
  sanitize_permissions
  release_lock

  echo
  print_ok "一键安装完成：新增 ${added} 个节点，失败 ${failed} 个。"
  echo
  print_node_list
  echo
  if [ "${failed}" -gt 0 ]; then
    exit 1
  fi
}

print_node_list() {
  local idx=1
  local tag protocol name port
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    protocol="$(node_value "$tag" "protocol")"
    name="$(node_value "$tag" "name")"
    port="$(node_value "$tag" "port")"
    echo "${idx}. ${name} | ${protocol} | 端口: ${port}"
    echo "   标识: ${tag}"
    echo "   链接: $(build_share_link "$tag")"
    idx=$((idx + 1))
  done < <(iter_node_tags)

  if [ "${idx}" -eq 1 ]; then
    echo "当前没有节点。"
  fi
}

select_node_tag() {
  local -a rows
  local idx input tag protocol name port
  mapfile -t rows < <(jq -r 'to_entries[] | [.key, .value.protocol, .value.name, (.value.port|tostring)] | @tsv' "${NODES_FILE}" 2>/dev/null)
  [ "${#rows[@]}" -gt 0 ] || return 1

  idx=1
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r tag protocol name port <<<"${row}"
    printf '%s\n' "${idx}. ${name} | ${protocol} | 端口: ${port}" >&2
    idx=$((idx + 1))
  done

  read -r -p "请选择节点编号: " input
  if ! [[ "${input}" =~ ^[0-9]+$ ]] || [ "${input}" -lt 1 ] || [ "${input}" -gt "${#rows[@]}" ]; then
    return 1
  fi

  IFS=$'\t' read -r tag _ <<<"${rows[$((input - 1))]}"
  printf '%s' "${tag}"
}

list_nodes() {
  init_storage
  echo
  print_node_list
  echo
}

delete_node() {
  local tag protocol cert_file key_file
  init_storage
  tag="$(select_node_tag)" || {
    print_warn "没有可选节点，或输入的编号无效。"
    return 1
  }

  protocol="$(node_value "$tag" "protocol")"
  if ! confirm_yes "确认删除节点 ${tag} 吗？"; then
    return 0
  fi

  acquire_lock
  cert_file="$(node_value "$tag" "certificate_path")"
  key_file="$(node_value "$tag" "key_path")"
  if [ "${protocol}" = "vless-argo" ]; then
    stop_argo_node "$tag"
  fi
  delete_node_records "$tag"
  render_config
  start_service
  remove_node_certificates "$tag" "$cert_file" "$key_file"
  sanitize_permissions
  release_lock
  print_ok "已删除节点：${tag}"
}

show_status() {
  local count installed_version
  init_storage
  detect_systemd
  count="$(jq 'length' "${NODES_FILE}" 2>/dev/null || printf '0')"
  installed_version="${SINGBOX_VERSION}"
  if [ -x "${SINGBOX_BIN}" ]; then
    installed_version="$("${SINGBOX_BIN}" version 2>/dev/null | head -n 1 | awk '{print $NF}')"
    installed_version="${installed_version:-${SINGBOX_VERSION}}"
  fi
  echo
  echo "项目名称：${PROJECT_NAME}"
  echo "当前版本：${SCRIPT_VERSION}"
  echo "服务状态：$(service_state)"
  echo "节点数量：${count}"
  if [ "${has_systemd}" = true ]; then
    echo "守护定时器：$(systemctl is-active "${WATCHDOG_TIMER_NAME}" 2>/dev/null || echo 未知)"
  elif [ "${has_openrc}" = true ]; then
    echo "守护方式：OpenRC + cron"
  else
    echo "守护方式：cron"
  fi
  echo "sing-box 版本：${installed_version}"
  echo "cloudflared 版本：$(cloudflared_installed_version)"
  echo
  print_node_list
  echo
}

restart_stack() {
  acquire_lock
  render_config
  start_service
  restart_all_argo_nodes
  sanitize_permissions
  release_lock
}

update_script() {
  local latest_tag
  if ! latest_tag="$(curl -fsSL --retry 3 --retry-delay 2 -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest" | jq -r '.tag_name // empty')"; then
    fatal "无法获取最新发布版本。"
  fi
  [ -n "${latest_tag}" ] || fatal "无法获取最新发布版本。"
  acquire_lock
  install_release_bundle "${latest_tag}"
  sanitize_permissions
  release_lock
  print_ok "项目文件已更新到 ${latest_tag}"
}

uninstall_project() {
  local tag
  if ! confirm_yes "这将卸载 ${PROJECT_NAME}，是否继续？"; then
    print_info "已取消卸载。"
    return 1
  fi

  detect_systemd
  acquire_lock
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    stop_argo_node "${tag}"
  done < <(iter_node_tags)

  stop_service || true

  if [ "${has_systemd}" = true ]; then
    systemctl disable --now "${WATCHDOG_TIMER_NAME}" >/dev/null 2>&1 || true
    systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
    rm -f "${SYSTEMD_SERVICE_FILE}" "${SYSTEMD_WATCHDOG_SERVICE_FILE}" "${SYSTEMD_WATCHDOG_TIMER_FILE}"
    systemctl daemon-reload || true
  elif [ "${has_openrc}" = true ]; then
    rc-update del "${SERVICE_NAME}" default >/dev/null 2>&1 || true
    rm -f "${OPENRC_SERVICE_FILE}"
  fi

  if command_exists crontab; then
    (crontab -l 2>/dev/null | grep -Fv "${WATCHDOG_TARGET}" | grep -Fv "no crontab for" || true) | crontab -
  fi

  rm -rf "${BASE_DIR}" "${LIB_DIR}" "${INSTALL_BIN}" "${SINGBOX_BIN}" "${CLOUDFLARED_BIN}"
  release_lock
  print_ok "项目已卸载。"
  return 0
}

menu_add_node() {
  echo
  echo "1. VLESS + Reality"
  echo "2. VLESS + WS + TLS"
  echo "3. AnyTLS"
  echo "4. VLESS + Argo"
  echo "5. TUIC v5"
  echo "6. Hysteria2"
  echo "7. SOCKS5"
  echo "0. 返回"
  echo
  read -r -p "请选择: " choice
  case "${choice}" in
  1) add_vless_reality ;;
  2) add_vless_ws_tls ;;
  3) add_anytls ;;
  4) add_vless_argo ;;
  5) add_tuic_v5 ;;
  6) add_hy2 ;;
  7) add_socks5 ;;
  0) return 0 ;;
  *) print_warn "无效的选择。" ;;
  esac
}

print_header() {
  clear 2>/dev/null || true
  echo "=============================================="
  echo "${PROJECT_NAME} ${SCRIPT_VERSION}"
  echo "=============================================="
  echo
}

ipver_display() {
  case "$(get_setting "ip_version" "4")" in
  6 | v6) printf 'v6' ;;
  auto) printf 'auto（v4 优先）' ;;
  *) printf 'v4（默认）' ;;
  esac
}

settings_menu() {
  local choice value
  while true; do
    print_header
    echo "全局设置"
    echo
    echo "1. 分享链接默认 IP 版本   当前：$(ipver_display)"
    echo "0. 返回"
    echo
    read -r -p "请选择: " choice
    case "${choice}" in
    1)
      read -r -p "IP 版本 (4/v6/auto) [4]: " value
      value="$(normalize_input "${value:-4}")"
      case "${value,,}" in
      4 | v4) set_setting "ip_version" "4" ;;
      6 | v6) set_setting "ip_version" "6" ;;
      auto) set_setting "ip_version" "auto" ;;
      *) print_warn "无效的值：${value}（可选 4 / v6 / auto）" ;;
      esac
      ;;
    0) return 0 ;;
    *)
      print_warn "无效的选择。"
      sleep 1
      ;;
    esac
  done
}

pause_menu() {
  read -r -p "按回车继续..." _
}

main_menu() {
  detect_systemd
  init_storage
  while true; do
    print_header
    echo "1. 安装/更新核心组件"
    echo "2. 添加节点"
    echo "3. 查看节点"
    echo "4. 删除节点"
    echo "5. 重启服务"
    echo "6. 查看状态"
    echo "7. 更新项目文件"
    echo "8. 卸载"
    echo "9. 全局设置"
    echo "0. 退出"
    echo
    read -r -p "请选择: " choice
    case "${choice}" in
    1)
      install_core
      pause_menu
      ;;
    2)
      menu_add_node
      pause_menu
      ;;
    3)
      list_nodes
      pause_menu
      ;;
    4)
      delete_node
      pause_menu
      ;;
    5)
      restart_stack
      pause_menu
      ;;
    6)
      show_status
      pause_menu
      ;;
    7)
      update_script
      pause_menu
      ;;
    8)
      if uninstall_project; then
        exit 0
      fi
      pause_menu
      ;;
    9)
      settings_menu
      ;;
    0) exit 0 ;;
    *)
      print_warn "无效的选择。"
      sleep 1
      ;;
    esac
  done
}

print_cli_usage() {
  cat <<EOF
用法: sbm [命令]

命令:
  (无参数)   打开交互式主菜单
  rep        覆盖式一键安装：清空已有节点，按环境变量重建并启动
  ins        追加式一键安装：保留已有节点，按环境变量追加节点并启动
  list       查看节点与分享链接
  delall     删除全部节点并重启服务
  un         卸载本项目

环境变量一键安装示例（配合网页命令生成器使用）:
  vlrt=2083 hypt=2082 name='HK' bash sb.sh rep
  支持的环境变量见 README「环境变量一键安装」章节。
EOF
}

main() {
  local action="${1:-}"
  case "${action}" in
  "")
    require_root
    main_menu
    ;;
  rep | ins)
    require_root
    auto_install "${action}"
    ;;
  list)
    require_root
    init_storage
    echo
    print_node_list
    echo
    ;;
  delall)
    require_root
    delete_all_nodes
    ;;
  un)
    require_root
    if uninstall_project; then
      exit 0
    fi
    exit 1
    ;;
  -h | --help | help)
    print_cli_usage
    ;;
  *)
    print_warn "未知命令：${action}"
    print_cli_usage
    exit 1
    ;;
  esac
}

if [ "${SBM_TEST_MODE:-0}" != "1" ]; then
  # 测试钩子：SBM_TEST_MODE=1 时供 tests/smoke.sh source 本文件做函数级验证
  main "$@"
fi
