#!/usr/bin/env bash
set -eEuo pipefail

umask 077

PROJECT_NAME="Singbox 管理器"
SCRIPT_VERSION="0.2.5"
REPO_OWNER="hynize"
REPO_NAME="singbox-manager"

INSTALL_BIN="/usr/local/bin/sbm"
LIB_DIR="/usr/local/lib/singbox-manager"
BASE_DIR="/usr/local/etc/singbox-manager"
WATCHDOG_TARGET="${BASE_DIR}/watchdog.sh"
UPSTREAM_ENV="${LIB_DIR}/upstream.env"
PID_FILE="${BASE_DIR}/runtime/sing-box.pid"

SINGBOX_BIN="/usr/local/bin/sing-box"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
SERVICE_NAME="singbox-manager"
WATCHDOG_SERVICE_NAME="singbox-manager-watchdog"
WATCHDOG_TIMER_NAME="singbox-manager-watchdog.timer"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SYSTEMD_WATCHDOG_SERVICE_FILE="/etc/systemd/system/${WATCHDOG_SERVICE_NAME}.service"
SYSTEMD_WATCHDOG_TIMER_FILE="/etc/systemd/system/${WATCHDOG_TIMER_NAME}"

DEFAULT_CDN_DOMAIN="saas.sin.fan"
DEFAULT_REALITY_SERVER="www.apple.com"
DEFAULT_TLS_SERVER="www.bing.com"

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

detect_systemd() {
  if command_exists systemctl && [ -d /run/systemd/system ]; then
    has_systemd=true
  else
    has_systemd=false
  fi
}

prompt_with_default() {
  local prompt="$1"
  local default="$2"
  local value
  read -r -p "${prompt} [${default}]: " value
  printf '%s' "${value:-$default}"
}

prompt_nonempty() {
  local prompt="$1"
  local value=""
  while [ -z "$value" ]; do
    read -r -p "${prompt}: " value
  done
  printf '%s' "$value"
}

confirm_yes() {
  local prompt="$1"
  local answer
  read -r -p "${prompt} [y/N]: " answer
  [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss]|是)$ ]]
}

prompt_choice() {
  local prompt="$1"
  local default="$2"
  local value
  read -r -p "${prompt} [${default}]: " value
  value="${value:-$default}"
  printf '%s' "${value,,}"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    armv7l|armv7) printf 'armv7' ;;
    armv6l|armv6) printf 'armv6' ;;
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

  local proc_tools=("kill" "rm" "mv" "chmod" "cat")
  required+=("${proc_tools[@]}")

  if [ "${has_systemd}" = true ]; then
    required+=("systemctl")
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
  local arch asset url tmpfile expected
  arch="$(detect_arch)" || fatal "暂不支持当前 CPU 架构：$(uname -m)"
  asset="${CLOUDFLARED_ASSET[$arch]:-}"
  expected="${CLOUDFLARED_SHA256[$arch]:-}"
  [ -n "${asset}" ] || fatal "未配置 ${arch} 对应的 cloudflared 安装包。"
  [ -n "${expected}" ] || fatal "未配置 ${arch} 对应的 cloudflared 校验值。"

  url="https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/${asset}"
  tmpfile="$(mktemp)"
  print_info "正在安装 cloudflared ${CLOUDFLARED_VERSION} (${arch})"
  download_file "${url}" "${tmpfile}"
  verify_sha256 "${tmpfile}" "${expected}"
  install -m 0755 "${tmpfile}" "${CLOUDFLARED_BIN}"
  ensure_binary_runs "${CLOUDFLARED_BIN}" "cloudflared" version
  rm -f "${tmpfile}"
  print_ok "cloudflared 已安装到 ${CLOUDFLARED_BIN}"
}

create_systemd_units() {
  cat > "${SYSTEMD_SERVICE_FILE}" <<EOF
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

  cat > "${SYSTEMD_WATCHDOG_SERVICE_FILE}" <<EOF
[Unit]
Description=Singbox Manager Watchdog
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${WATCHDOG_TARGET}
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

  cat > "${SYSTEMD_WATCHDOG_TIMER_FILE}" <<EOF
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

create_cron_watchdog() {
  if ! command_exists crontab; then
    print_warn "未找到 crontab，已跳过 watchdog 的 cron 创建。"
    return 0
  fi

  (
    crontab -l 2>/dev/null | grep -Fv "${WATCHDOG_TARGET}" || true
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
  else
    kill_pid_file "${PID_FILE}"
  fi
}

start_service() {
  detect_systemd
  [ -x "${SINGBOX_BIN}" ] || fatal "尚未安装 sing-box。"
  "${SINGBOX_BIN}" check -c "${CONFIG_FILE}" >/dev/null

  if [ "${has_systemd}" = true ]; then
    systemctl daemon-reload
    systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || systemctl start "${SERVICE_NAME}" >/dev/null 2>&1
    systemctl enable --now "${WATCHDOG_TIMER_NAME}" >/dev/null 2>&1 || true
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
  if [ "${has_systemd}" = true ]; then
    create_systemd_units
  else
    create_cron_watchdog
  fi
  render_config
  start_service
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
    ss -ltnuH 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}$"
  elif command_exists netstat; then
    netstat -lntup 2>/dev/null | awk 'NR>2 {print $4}' | grep -Eq "[:.]${port}$"
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

prompt_certificate_bundle() {
  local tag="$1"
  local default_domain="$2"
  local mode cert_path key_path pair

  while true; do
    mode="$(prompt_choice "证书模式 (self-signed/custom)" "self-signed")"
    case "$mode" in
      self-signed|self|quick)
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
        printf 'custom|%s|%s' "$cert_path" "$key_path"
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
  [ -n "${cert_file}" ] && [ -f "${cert_file}" ] && rm -f "${cert_file}"
  [ -n "${key_file}" ] && [ -f "${key_file}" ] && rm -f "${key_file}"
  render_config || true
}

save_node_bundle() {
  local tag="$1"
  local node_json="$2"
  local secret_json="$3"
  json_set_record "${NODES_FILE}" "$tag" "$node_json"
  json_set_record "${SECRETS_FILE}" "$tag" "$secret_json"
}

render_config() {
  local inbounds_json tmp
  inbounds_json="$(
    while IFS= read -r tag; do
      [ -n "${tag}" ] || continue
      render_inbound_for_tag "${tag}"
    done < <(iter_node_tags)
  )"

  if [ -n "${inbounds_json}" ]; then
    inbounds_json="$(printf '%s\n' "${inbounds_json}" | jq -s '.')"
  else
    inbounds_json='[]'
  fi

  tmp="$(mktemp "${BASE_DIR}/.config.XXXXXX")"
  jq -n --arg log_path "${BASE_DIR}/logs/sing-box.log" --argjson inbounds "${inbounds_json}" '{
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
  }' > "${tmp}"
  chmod 600 "${tmp}"
  mv "${tmp}" "${CONFIG_FILE}"
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
      jq -n \
        --arg tag "$tag" \
        --arg name "$name" \
        --arg password "$password" \
        --arg cert_file "$cert_file" \
        --arg key_file "$key_file" \
        --argjson port "$port" '{
          type: "hysteria2",
          tag: $tag,
          listen: "::",
          listen_port: $port,
          users: [{ name: $name, password: $password }],
          up_mbps: 200,
          down_mbps: 200,
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
  esac
}

stop_argo_node() {
  local tag="$1"
  kill_pid_file "${BASE_DIR}/runtime/${tag}.pid"
}

start_argo_node() {
  local tag="$1"
  local mode port token log_file pid_file domain

  [ -x "${CLOUDFLARED_BIN}" ] || install_cloudflared_bin
  mode="$(node_value "$tag" "argo_mode")"
  port="$(node_value "$tag" "port")"
  log_file="${BASE_DIR}/logs/${tag}.cloudflared.log"
  pid_file="${BASE_DIR}/runtime/${tag}.pid"

  stop_argo_node "$tag"
  : > "${log_file}"
  chmod 600 "${log_file}"

  if [ "${mode}" = "token" ]; then
    token="$(secret_value "$tag" "argo_token")"
    nohup "${CLOUDFLARED_BIN}" tunnel --no-autoupdate --edge-ip-version auto run --token "${token}" \
      >"${log_file}" 2>&1 &
    write_pid_file "${pid_file}" "$!"
    return 0
  fi

  nohup "${CLOUDFLARED_BIN}" tunnel --no-autoupdate --edge-ip-version auto --url "http://127.0.0.1:${port}" \
    >"${log_file}" 2>&1 &
  write_pid_file "${pid_file}" "$!"

  if domain="$(wait_for_trycloudflare_domain "${log_file}" 60 2)"; then
    json_set_field "${NODES_FILE}" "${tag}" "endpoint_domain" "${domain}"
  else
    fatal "等待 ${tag} 的临时 Argo 域名超时。"
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
  read -r -p "UUID（留空自动生成）: " uuid
  uuid="${uuid:-$(generate_uuid)}"
  reality_server="$(prompt_with_default "Reality 域名" "${DEFAULT_REALITY_SERVER}")"

  key_output="$("${SINGBOX_BIN}" generate reality-keypair)"
  private_key="$(printf '%s\n' "$key_output" | awk -F': ' '/PrivateKey/ {print $2; exit}')"
  public_key="$(printf '%s\n' "$key_output" | awk -F': ' '/PublicKey/ {print $2; exit}')"
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

  save_node_bundle "$tag" "$node_json" "$secret_json"
  render_config
  start_service
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
  read -r -p "UUID（留空自动生成）: " uuid
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
  read -r -p "密码（留空自动生成）: " password
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
  read -r -p "UUID（留空自动生成）: " uuid
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
  read -r -p "UUID（留空自动生成）: " uuid
  uuid="${uuid:-$(generate_uuid)}"
  read -r -p "密码（留空自动生成）: " password
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
  local tag port name password tls_server cert_bundle cert_mode cert_file key_file node_json secret_json
  ensure_singbox_ready
  acquire_lock
  tag="$(generate_tag "hy2")"
  port="$(prompt_port 11443)"
  name="$(prompt_with_default "节点名称" "Hysteria2")"
  read -r -p "密码（留空自动生成）: " password
  password="${password:-$(generate_hex 8)}"
  tls_server="$(prompt_with_default "SNI 域名" "${DEFAULT_TLS_SERVER}")"
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

add_socks5() {
  local tag port name username password node_json secret_json
  ensure_singbox_ready
  acquire_lock
  tag="$(generate_tag "socks5")"
  port="$(prompt_port 1080)"
  name="$(prompt_with_default "节点名称" "SOCKS5")"
  username="$(prompt_with_default "用户名" "user")"
  read -r -p "密码（留空自动生成）: " password
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
    IFS=$'\t' read -r tag protocol name port <<< "${row}"
    printf '%s\n' "${idx}. ${name} | ${protocol} | 端口: ${port}" >&2
    idx=$((idx + 1))
  done

  read -r -p "请选择节点编号: " input
  if ! [[ "${input}" =~ ^[0-9]+$ ]] || [ "${input}" -lt 1 ] || [ "${input}" -gt "${#rows[@]}" ]; then
    return 1
  fi

  IFS=$'\t' read -r tag _ <<< "${rows[$((input - 1))]}"
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
  [ -n "${cert_file}" ] && [ -f "${cert_file}" ] && rm -f "${cert_file}"
  [ -n "${key_file}" ] && [ -f "${key_file}" ] && rm -f "${key_file}"
  sanitize_permissions
  release_lock
  print_ok "已删除节点：${tag}"
}

show_status() {
  local count
  init_storage
  detect_systemd
  count="$(jq 'length' "${NODES_FILE}" 2>/dev/null || printf '0')"
  echo
  echo "项目名称：${PROJECT_NAME}"
  echo "当前版本：${SCRIPT_VERSION}"
  echo "服务状态：$(service_state)"
  echo "节点数量：${count}"
  if [ "${has_systemd}" = true ]; then
    echo "守护定时器：$(systemctl is-active "${WATCHDOG_TIMER_NAME}" 2>/dev/null || echo 未知)"
  else
    echo "守护方式：cron"
  fi
  echo "锁定 sing-box 版本：${SINGBOX_VERSION}"
  echo "锁定 cloudflared 版本：${CLOUDFLARED_VERSION}"
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
  latest_tag="$(curl -fsSL "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest" | jq -r '.tag_name')"
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
    return 0
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
  elif command_exists crontab; then
    (crontab -l 2>/dev/null | grep -Fv "${WATCHDOG_TARGET}" || true) | crontab -
  fi

  rm -rf "${BASE_DIR}" "${LIB_DIR}" "${INSTALL_BIN}" "${SINGBOX_BIN}" "${CLOUDFLARED_BIN}"
  release_lock
  print_ok "项目已卸载。"
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
    echo "0. 退出"
    echo
    read -r -p "请选择: " choice
    case "${choice}" in
      1) install_core ;;
      2) menu_add_node ;;
      3) list_nodes; read -r -p "按回车继续..." _ ;;
      4) delete_node; read -r -p "按回车继续..." _ ;;
      5) restart_stack; read -r -p "按回车继续..." _ ;;
      6) show_status; read -r -p "按回车继续..." _ ;;
      7) update_script; read -r -p "按回车继续..." _ ;;
      8) uninstall_project; exit 0 ;;
      0) exit 0 ;;
      *) print_warn "无效的选择。"; sleep 1 ;;
    esac
  done
}

require_root
main_menu
