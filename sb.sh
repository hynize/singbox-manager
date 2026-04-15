#!/usr/bin/env bash
set -uo pipefail

PROJECT_NAME="Singbox Manager"
SCRIPT_VERSION="0.1.0"
REPO_OWNER="hynize"
REPO_NAME="singbox-manager"
RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_BIN="/usr/local/bin/sbm"
SINGBOX_BIN="/usr/local/bin/sing-box"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"

BASE_DIR="/usr/local/etc/singbox-manager"
CONFIG_FILE="${BASE_DIR}/config.json"
META_FILE="${BASE_DIR}/nodes.json"
CERT_DIR="${BASE_DIR}/certs"
LOG_DIR="${BASE_DIR}/logs"
RUNTIME_DIR="${BASE_DIR}/runtime"
WATCHDOG_TARGET="${BASE_DIR}/watchdog.sh"

SERVICE_NAME="singbox-manager"
WATCHDOG_SERVICE_NAME="singbox-manager-watchdog"
WATCHDOG_TIMER_NAME="singbox-manager-watchdog.timer"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SYSTEMD_WATCHDOG_SERVICE_FILE="/etc/systemd/system/${WATCHDOG_SERVICE_NAME}.service"
SYSTEMD_WATCHDOG_TIMER_FILE="/etc/systemd/system/${WATCHDOG_TIMER_NAME}"

DEFAULT_CDN_DOMAIN="saas.sin.fan"
DEFAULT_REALITY_SERVER="www.apple.com"
DEFAULT_TLS_SERVER="www.bing.com"

COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_RED="\033[1;31m"
COLOR_BLUE="\033[1;34m"
COLOR_RESET="\033[0m"

has_systemd=false

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Please run as root."
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

detect_systemd() {
  if command_exists systemctl && [ -d /run/systemd/system ]; then
    has_systemd=true
  else
    has_systemd=false
  fi
}

print_ok() {
  echo -e "${COLOR_GREEN}[OK]${COLOR_RESET} $*"
}

print_warn() {
  echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"
}

print_err() {
  echo -e "${COLOR_RED}[ERR]${COLOR_RESET} $*"
}

print_info() {
  echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"
}

download_file() {
  local url="$1"
  local out="$2"
  if command_exists curl; then
    curl -fsSL "$url" -o "$out"
  elif command_exists wget; then
    wget -qO "$out" "$url"
  else
    print_err "curl or wget is required."
    return 1
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
  [[ "$answer" =~ ^[Yy]$ ]]
}

url_encode() {
  jq -nr --arg s "$1" '$s|@uri'
}

wrap_host() {
  local host="$1"
  if [[ "$host" == *:* ]] && [[ "$host" != \[*\] ]]; then
    printf '[%s]' "$host"
  else
    printf '%s' "$host"
  fi
}

get_public_ip() {
  local ip
  for url in \
    "https://api64.ipify.org" \
    "https://ipv4.icanhazip.com" \
    "https://ifconfig.me/ip"; do
    ip="$(curl -4 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '\r\n' || true)"
    if [ -n "$ip" ]; then
      printf '%s' "$ip"
      return 0
    fi
  done
  hostname -I 2>/dev/null | awk '{print $1}'
}

generate_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  elif command_exists uuidgen; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    printf '%s-%s-%s-%s-%s\n' \
      "$(openssl rand -hex 4)" \
      "$(openssl rand -hex 2)" \
      "$(openssl rand -hex 2)" \
      "$(openssl rand -hex 2)" \
      "$(openssl rand -hex 6)"
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
  printf '%s-%s-%s' "$prefix" "$(date +%s)" "$(generate_hex 2)"
}

init_storage() {
  mkdir -p "${BASE_DIR}" "${CERT_DIR}" "${LOG_DIR}" "${RUNTIME_DIR}"
  [ -f "${META_FILE}" ] || printf '{}\n' > "${META_FILE}"
  [ -f "${CONFIG_FILE}" ] || printf '{}\n' > "${CONFIG_FILE}"
}

pkg_install() {
  local packages=("$@")
  if [ "${#packages[@]}" -eq 0 ]; then
    return 0
  fi

  if command_exists apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "${packages[@]}"
  elif command_exists dnf; then
    dnf install -y "${packages[@]}"
  elif command_exists yum; then
    yum install -y "${packages[@]}"
  elif command_exists apk; then
    apk add --no-cache "${packages[@]}"
  elif command_exists pacman; then
    pacman -Sy --noconfirm "${packages[@]}"
  elif command_exists zypper; then
    zypper --non-interactive install "${packages[@]}"
  else
    print_err "Unsupported package manager. Please install manually: ${packages[*]}"
    return 1
  fi
}

ensure_dependencies() {
  local missing=()
  command_exists curl || missing+=("curl")
  command_exists tar || missing+=("tar")
  command_exists jq || missing+=("jq")
  command_exists openssl || missing+=("openssl")
  if [ "${#missing[@]}" -gt 0 ]; then
    print_info "Installing dependencies: ${missing[*]}"
    pkg_install "${missing[@]}" || return 1
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    armv7l|armv7) printf 'armv7' ;;
    armv6l|armv6) printf 'arm' ;;
    *) return 1 ;;
  esac
}

latest_release_tag() {
  local repo="$1"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name'
}

install_singbox_core() {
  local arch tag version url tmpdir archive bin_path
  arch="$(detect_arch)" || {
    print_err "Unsupported CPU architecture: $(uname -m)"
    return 1
  }
  tag="$(latest_release_tag "SagerNet/sing-box")" || return 1
  version="${tag#v}"
  url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${version}-linux-${arch}.tar.gz"
  tmpdir="$(mktemp -d)"
  archive="${tmpdir}/sing-box.tar.gz"

  print_info "Downloading sing-box ${tag}"
  download_file "$url" "$archive" || {
    rm -rf "$tmpdir"
    return 1
  }

  tar -xzf "$archive" -C "$tmpdir"
  bin_path="$(find "$tmpdir" -type f -name sing-box | head -n 1)"
  if [ -z "$bin_path" ]; then
    rm -rf "$tmpdir"
    print_err "sing-box binary not found in release archive."
    return 1
  fi

  install -m 0755 "$bin_path" "${SINGBOX_BIN}"
  rm -rf "$tmpdir"
  print_ok "sing-box installed to ${SINGBOX_BIN}"
}

install_cloudflared_bin() {
  local arch asset url tmpfile
  arch="$(detect_arch)" || {
    print_err "Unsupported CPU architecture: $(uname -m)"
    return 1
  }

  case "$arch" in
    amd64) asset="cloudflared-linux-amd64" ;;
    arm64) asset="cloudflared-linux-arm64" ;;
    armv7|arm) asset="cloudflared-linux-arm" ;;
    *) print_err "Unsupported cloudflared architecture: $arch"; return 1 ;;
  esac

  url="https://github.com/cloudflare/cloudflared/releases/latest/download/${asset}"
  tmpfile="$(mktemp)"
  print_info "Downloading cloudflared"
  download_file "$url" "$tmpfile" || {
    rm -f "$tmpfile"
    return 1
  }
  install -m 0755 "$tmpfile" "${CLOUDFLARED_BIN}"
  rm -f "$tmpfile"
  print_ok "cloudflared installed to ${CLOUDFLARED_BIN}"
}

copy_watchdog_asset() {
  if [ -f "${SCRIPT_DIR}/scripts/watchdog.sh" ]; then
    install -m 0755 "${SCRIPT_DIR}/scripts/watchdog.sh" "${WATCHDOG_TARGET}"
  else
    download_file "${RAW_BASE}/scripts/watchdog.sh" "${WATCHDOG_TARGET}" || return 1
    chmod +x "${WATCHDOG_TARGET}"
  fi
}

create_systemd_units() {
  cat > "${SYSTEMD_SERVICE_FILE}" <<EOF
[Unit]
Description=Singbox Manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SINGBOX_BIN} run -c ${CONFIG_FILE}
Restart=always
RestartSec=3

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
    print_warn "crontab not found, skipping watchdog cron creation."
    return 0
  fi

  (
    crontab -l 2>/dev/null | grep -Fv "${WATCHDOG_TARGET}" || true
    echo "* * * * * ${WATCHDOG_TARGET} >/dev/null 2>&1"
  ) | crontab -
}

service_state() {
  if [ "${has_systemd}" = true ]; then
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
      printf 'running'
    else
      printf 'stopped'
    fi
  else
    local pid_file="${RUNTIME_DIR}/sing-box.pid"
    if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file" 2>/dev/null)" >/dev/null 2>&1; then
      printf 'running'
    elif pgrep -f "${SINGBOX_BIN} run -c ${CONFIG_FILE}" >/dev/null 2>&1; then
      printf 'running'
    else
      printf 'stopped'
    fi
  fi
}

stop_service() {
  if [ "${has_systemd}" = true ]; then
    systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
  else
    local pid_file="${RUNTIME_DIR}/sing-box.pid"
    if [ -f "$pid_file" ]; then
      kill "$(cat "$pid_file" 2>/dev/null)" >/dev/null 2>&1 || true
      rm -f "$pid_file"
    fi
    pkill -f "${SINGBOX_BIN} run -c ${CONFIG_FILE}" >/dev/null 2>&1 || true
  fi
}

start_service() {
  if [ ! -x "${SINGBOX_BIN}" ]; then
    print_err "sing-box is not installed yet."
    return 1
  fi

  if ! "${SINGBOX_BIN}" check -c "${CONFIG_FILE}" >/dev/null 2>&1; then
    print_err "Configuration validation failed. Please check ${CONFIG_FILE}"
    "${SINGBOX_BIN}" check -c "${CONFIG_FILE}" || true
    return 1
  fi

  if [ "${has_systemd}" = true ]; then
    systemctl daemon-reload
    systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || systemctl start "${SERVICE_NAME}" >/dev/null 2>&1 || return 1
    systemctl enable --now "${WATCHDOG_TIMER_NAME}" >/dev/null 2>&1 || true
  else
    stop_service
    nohup "${SINGBOX_BIN}" run -c "${CONFIG_FILE}" >>"${LOG_DIR}/sing-box.log" 2>&1 &
    echo $! > "${RUNTIME_DIR}/sing-box.pid"
  fi
  print_ok "Service state: $(service_state)"
}

install_core() {
  ensure_dependencies || return 1
  detect_systemd
  init_storage
  install_singbox_core || return 1
  copy_watchdog_asset || return 1
  if [ "${has_systemd}" = true ]; then
    create_systemd_units || return 1
  else
    create_cron_watchdog || true
  fi
  render_config || return 1
  start_service || return 1
}

ensure_singbox_ready() {
  init_storage
  if [ ! -x "${SINGBOX_BIN}" ]; then
    print_info "sing-box not installed, installing now."
    install_core || return 1
  fi
}

metadata_has_port() {
  local port="$1"
  jq -e --argjson port "$port" 'to_entries | any(.value.port == $port)' "${META_FILE}" >/dev/null 2>&1
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
    port="$(prompt_with_default "Port" "$default")"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
      print_warn "Invalid port: ${port}"
      continue
    fi
    if ! port_available "$port"; then
      print_warn "Port ${port} is already in use."
      continue
    fi
    printf '%s' "$port"
    return 0
  done
}

save_node() {
  local tag="$1"
  local json="$2"
  local tmp
  tmp="$(mktemp)"
  jq --arg tag "$tag" --argjson value "$json" '.[$tag] = $value' "${META_FILE}" > "${tmp}" && mv "${tmp}" "${META_FILE}"
}

delete_node_key() {
  local tag="$1"
  local tmp
  tmp="$(mktemp)"
  jq --arg tag "$tag" 'del(.[$tag])' "${META_FILE}" > "${tmp}" && mv "${tmp}" "${META_FILE}"
}

ensure_tls_material() {
  local tag="$1"
  local domain="$2"
  local cert_file="${CERT_DIR}/${tag}.crt"
  local key_file="${CERT_DIR}/${tag}.key"
  local san

  if [ -f "$cert_file" ] && [ -f "$key_file" ]; then
    printf '%s|%s' "$cert_file" "$key_file"
    return 0
  fi

  if [[ "$domain" =~ ^[0-9a-fA-F:.]+$ ]]; then
    san="IP:${domain}"
  else
    san="DNS:${domain}"
  fi

  if ! openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$key_file" \
    -out "$cert_file" \
    -subj "/CN=${domain}" \
    -addext "subjectAltName=${san}" >/dev/null 2>&1; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -keyout "$key_file" \
      -out "$cert_file" \
      -subj "/CN=${domain}" >/dev/null 2>&1 || return 1
  fi

  printf '%s|%s' "$cert_file" "$key_file"
}

render_config() {
  local inbounds_json tmp
  inbounds_json="$(
    while IFS= read -r tag; do
      [ -n "$tag" ] || continue
      render_inbound_for_tag "$tag"
    done < <(jq -r 'keys[]' "${META_FILE}" 2>/dev/null)
  )"

  if [ -n "$inbounds_json" ]; then
    inbounds_json="$(printf '%s\n' "$inbounds_json" | jq -s '.')"
  else
    inbounds_json='[]'
  fi

  tmp="$(mktemp)"
  jq -n --arg log_path "${LOG_DIR}/sing-box.log" --argjson inbounds "${inbounds_json}" '{
    log: {
      level: "info",
      output: $log_path,
      timestamp: true
    },
    inbounds: $inbounds,
    outbounds: [
      {
        type: "direct",
        tag: "direct"
      }
    ],
    route: {
      final: "direct",
      auto_detect_interface: true
    }
  }' > "${tmp}" && mv "${tmp}" "${CONFIG_FILE}"
}

render_inbound_for_tag() {
  local tag="$1"
  local protocol name port uuid password cert_file key_file ws_path tls_server reality_server
  protocol="$(jq -r --arg tag "$tag" '.[$tag].protocol' "${META_FILE}")"
  name="$(jq -r --arg tag "$tag" '.[$tag].name' "${META_FILE}")"
  port="$(jq -r --arg tag "$tag" '.[$tag].port' "${META_FILE}")"

  case "$protocol" in
    vless-reality)
      uuid="$(jq -r --arg tag "$tag" '.[$tag].uuid' "${META_FILE}")"
      reality_server="$(jq -r --arg tag "$tag" '.[$tag].reality_server' "${META_FILE}")"
      jq -n \
        --arg tag "$tag" \
        --arg name "$name" \
        --arg uuid "$uuid" \
        --arg reality_server "$reality_server" \
        --arg private_key "$(jq -r --arg tag "$tag" '.[$tag].private_key' "${META_FILE}")" \
        --arg short_id "$(jq -r --arg tag "$tag" '.[$tag].short_id' "${META_FILE}")" \
        --argjson port "$port" '{
          type: "vless",
          tag: $tag,
          listen: "::",
          listen_port: $port,
          users: [
            {
              name: $name,
              uuid: $uuid,
              flow: "xtls-rprx-vision"
            }
          ],
          tls: {
            enabled: true,
            server_name: $reality_server,
            reality: {
              enabled: true,
              handshake: {
                server: $reality_server,
                server_port: 443
              },
              private_key: $private_key,
              short_id: [$short_id]
            }
          }
        }'
      ;;
    vless-ws-tls)
      uuid="$(jq -r --arg tag "$tag" '.[$tag].uuid' "${META_FILE}")"
      ws_path="$(jq -r --arg tag "$tag" '.[$tag].ws_path' "${META_FILE}")"
      cert_file="$(jq -r --arg tag "$tag" '.[$tag].certificate_path' "${META_FILE}")"
      key_file="$(jq -r --arg tag "$tag" '.[$tag].key_path' "${META_FILE}")"
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
          users: [
            {
              name: $name,
              uuid: $uuid
            }
          ],
          tls: {
            enabled: true,
            certificate_path: $cert_file,
            key_path: $key_file
          },
          transport: {
            type: "ws",
            path: $ws_path
          }
        }'
      ;;
    anytls)
      password="$(jq -r --arg tag "$tag" '.[$tag].password' "${META_FILE}")"
      cert_file="$(jq -r --arg tag "$tag" '.[$tag].certificate_path' "${META_FILE}")"
      key_file="$(jq -r --arg tag "$tag" '.[$tag].key_path' "${META_FILE}")"
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
          users: [
            {
              name: $name,
              password: $password
            }
          ],
          tls: {
            enabled: true,
            certificate_path: $cert_file,
            key_path: $key_file
          }
        }'
      ;;
    vless-argo)
      uuid="$(jq -r --arg tag "$tag" '.[$tag].uuid' "${META_FILE}")"
      ws_path="$(jq -r --arg tag "$tag" '.[$tag].ws_path' "${META_FILE}")"
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
          users: [
            {
              name: $name,
              uuid: $uuid
            }
          ],
          transport: {
            type: "ws",
            path: $ws_path
          }
        }'
      ;;
    tuic-v5)
      uuid="$(jq -r --arg tag "$tag" '.[$tag].uuid' "${META_FILE}")"
      password="$(jq -r --arg tag "$tag" '.[$tag].password' "${META_FILE}")"
      cert_file="$(jq -r --arg tag "$tag" '.[$tag].certificate_path' "${META_FILE}")"
      key_file="$(jq -r --arg tag "$tag" '.[$tag].key_path' "${META_FILE}")"
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
          users: [
            {
              name: $name,
              uuid: $uuid,
              password: $password
            }
          ],
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
      password="$(jq -r --arg tag "$tag" '.[$tag].password' "${META_FILE}")"
      cert_file="$(jq -r --arg tag "$tag" '.[$tag].certificate_path' "${META_FILE}")"
      key_file="$(jq -r --arg tag "$tag" '.[$tag].key_path' "${META_FILE}")"
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
          users: [
            {
              name: $name,
              password: $password
            }
          ],
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
        --arg username "$(jq -r --arg tag "$tag" '.[$tag].username' "${META_FILE}")" \
        --arg password "$(jq -r --arg tag "$tag" '.[$tag].password' "${META_FILE}")" \
        --argjson port "$port" '{
          type: "socks",
          tag: $tag,
          listen: "::",
          listen_port: $port,
          users: [
            {
              username: $username,
              password: $password
            }
          ]
        }'
      ;;
  esac
}

build_share_link() {
  local tag="$1"
  local protocol host public_ip name port uuid password username reality_server public_key short_id ws_path preferred_domain endpoint_domain host_domain tls_server
  protocol="$(jq -r --arg tag "$tag" '.[$tag].protocol' "${META_FILE}")"
  name="$(jq -r --arg tag "$tag" '.[$tag].name' "${META_FILE}")"
  port="$(jq -r --arg tag "$tag" '.[$tag].port' "${META_FILE}")"
  public_ip="$(get_public_ip)"
  host="$(wrap_host "$public_ip")"

  case "$protocol" in
    vless-reality)
      uuid="$(jq -r --arg tag "$tag" '.[$tag].uuid' "${META_FILE}")"
      reality_server="$(jq -r --arg tag "$tag" '.[$tag].reality_server' "${META_FILE}")"
      public_key="$(jq -r --arg tag "$tag" '.[$tag].public_key' "${META_FILE}")"
      short_id="$(jq -r --arg tag "$tag" '.[$tag].short_id' "${META_FILE}")"
      printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
        "$uuid" "$host" "$port" "$reality_server" "$public_key" "$short_id" "$(url_encode "$name")"
      ;;
    vless-ws-tls)
      uuid="$(jq -r --arg tag "$tag" '.[$tag].uuid' "${META_FILE}")"
      ws_path="$(jq -r --arg tag "$tag" '.[$tag].ws_path' "${META_FILE}")"
      preferred_domain="$(jq -r --arg tag "$tag" '.[$tag].preferred_domain' "${META_FILE}")"
      host_domain="$(jq -r --arg tag "$tag" '.[$tag].host_domain' "${META_FILE}")"
      printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s&allowInsecure=1#%s' \
        "$uuid" "$(wrap_host "$preferred_domain")" "$port" "$host_domain" "$host_domain" "$(url_encode "$ws_path")" "$(url_encode "$name")"
      ;;
    anytls)
      password="$(jq -r --arg tag "$tag" '.[$tag].password' "${META_FILE}")"
      tls_server="$(jq -r --arg tag "$tag" '.[$tag].tls_server' "${META_FILE}")"
      printf 'anytls://%s@%s:%s?security=tls&sni=%s&allowInsecure=1#%s' \
        "$(url_encode "$password")" "$host" "$port" "$tls_server" "$(url_encode "$name")"
      ;;
    vless-argo)
      uuid="$(jq -r --arg tag "$tag" '.[$tag].uuid' "${META_FILE}")"
      ws_path="$(jq -r --arg tag "$tag" '.[$tag].ws_path' "${META_FILE}")"
      preferred_domain="$(jq -r --arg tag "$tag" '.[$tag].preferred_domain' "${META_FILE}")"
      endpoint_domain="$(jq -r --arg tag "$tag" '.[$tag].endpoint_domain' "${META_FILE}")"
      [ -n "$endpoint_domain" ] && [ "$endpoint_domain" != "null" ] || endpoint_domain="pending.example.com"
      printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s#%s' \
        "$uuid" "$(wrap_host "$preferred_domain")" "$endpoint_domain" "$endpoint_domain" "$(url_encode "$ws_path")" "$(url_encode "$name")"
      ;;
    tuic-v5)
      uuid="$(jq -r --arg tag "$tag" '.[$tag].uuid' "${META_FILE}")"
      password="$(jq -r --arg tag "$tag" '.[$tag].password' "${META_FILE}")"
      tls_server="$(jq -r --arg tag "$tag" '.[$tag].tls_server' "${META_FILE}")"
      printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&alpn=h3&sni=%s&allow_insecure=1&allowInsecure=1#%s' \
        "$uuid" "$(url_encode "$password")" "$host" "$port" "$tls_server" "$(url_encode "$name")"
      ;;
    hy2)
      password="$(jq -r --arg tag "$tag" '.[$tag].password' "${META_FILE}")"
      tls_server="$(jq -r --arg tag "$tag" '.[$tag].tls_server' "${META_FILE}")"
      printf 'hysteria2://%s@%s:%s?sni=%s&insecure=1#%s' \
        "$(url_encode "$password")" "$host" "$port" "$tls_server" "$(url_encode "$name")"
      ;;
    socks5)
      username="$(jq -r --arg tag "$tag" '.[$tag].username' "${META_FILE}")"
      password="$(jq -r --arg tag "$tag" '.[$tag].password' "${META_FILE}")"
      printf 'socks5://%s:%s@%s:%s#%s' \
        "$(url_encode "$username")" "$(url_encode "$password")" "$host" "$port" "$(url_encode "$name")"
      ;;
  esac
}

refresh_node_share_link() {
  local tag="$1"
  local share tmp
  share="$(build_share_link "$tag")"
  tmp="$(mktemp)"
  jq --arg tag "$tag" --arg share "$share" '.[$tag].share_link = $share' "${META_FILE}" > "${tmp}" && mv "${tmp}" "${META_FILE}"
}

refresh_all_share_links() {
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    refresh_node_share_link "$tag"
  done < <(jq -r 'keys[]' "${META_FILE}" 2>/dev/null)
}

stop_argo_node() {
  local tag="$1"
  local pid_file="${RUNTIME_DIR}/${tag}.pid"
  if [ -f "$pid_file" ]; then
    kill "$(cat "$pid_file" 2>/dev/null)" >/dev/null 2>&1 || true
    rm -f "$pid_file"
  fi
}

start_argo_node() {
  local tag="$1"
  local mode port token endpoint_domain log_file pid_file tmp
  install_cloudflared_bin >/dev/null 2>&1 || true
  [ -x "${CLOUDFLARED_BIN}" ] || {
    print_err "cloudflared install failed."
    return 1
  }

  stop_argo_node "$tag"
  mode="$(jq -r --arg tag "$tag" '.[$tag].argo_mode' "${META_FILE}")"
  port="$(jq -r --arg tag "$tag" '.[$tag].port' "${META_FILE}")"
  log_file="${LOG_DIR}/${tag}.cloudflared.log"
  pid_file="${RUNTIME_DIR}/${tag}.pid"

  if [ "$mode" = "token" ]; then
    token="$(jq -r --arg tag "$tag" '.[$tag].argo_token' "${META_FILE}")"
    endpoint_domain="$(jq -r --arg tag "$tag" '.[$tag].endpoint_domain' "${META_FILE}")"
    nohup "${CLOUDFLARED_BIN}" tunnel --no-autoupdate --edge-ip-version auto run --token "${token}" >"${log_file}" 2>&1 &
    echo $! > "${pid_file}"
  else
    nohup "${CLOUDFLARED_BIN}" tunnel --no-autoupdate --edge-ip-version auto --url "http://127.0.0.1:${port}" >"${log_file}" 2>&1 &
    echo $! > "${pid_file}"
    sleep 6
    endpoint_domain="$(grep -aoE 'https://[-a-z0-9]+\.trycloudflare\.com' "${log_file}" | head -n 1 | sed 's#https://##')"
    if [ -n "$endpoint_domain" ]; then
      tmp="$(mktemp)"
      jq --arg tag "$tag" --arg domain "$endpoint_domain" \
        '.[$tag].endpoint_domain = $domain' "${META_FILE}" > "${tmp}" && mv "${tmp}" "${META_FILE}"
      refresh_node_share_link "$tag"
    fi
  fi
}

restart_all_argo_nodes() {
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    if [ "$(jq -r --arg tag "$tag" '.[$tag].protocol' "${META_FILE}")" = "vless-argo" ]; then
      start_argo_node "$tag"
    fi
  done < <(jq -r 'keys[]' "${META_FILE}" 2>/dev/null)
}

add_vless_reality() {
  local tag port name uuid reality_server key_output private_key public_key short_id node_json
  ensure_singbox_ready || return 1
  tag="$(generate_tag "vless-reality")"
  port="$(prompt_port 443)"
  name="$(prompt_with_default "Node name" "VLESS-Reality")"
  read -r -p "UUID (leave blank to auto generate): " uuid
  uuid="${uuid:-$(generate_uuid)}"
  reality_server="$(prompt_with_default "Reality server name" "${DEFAULT_REALITY_SERVER}")"

  key_output="$("${SINGBOX_BIN}" generate reality-keypair)"
  private_key="$(printf '%s\n' "$key_output" | awk -F': ' '/PrivateKey/ {print $2; exit}')"
  public_key="$(printf '%s\n' "$key_output" | awk -F': ' '/PublicKey/ {print $2; exit}')"
  short_id="$(generate_hex 4)"

  node_json="$(jq -n \
    --arg protocol "vless-reality" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg uuid "$uuid" \
    --arg reality_server "$reality_server" \
    --arg private_key "$private_key" \
    --arg public_key "$public_key" \
    --arg short_id "$short_id" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      uuid: $uuid,
      reality_server: $reality_server,
      private_key: $private_key,
      public_key: $public_key,
      short_id: $short_id
    }')"

  save_node "$tag" "$node_json"
  render_config && refresh_node_share_link "$tag" && start_service
  print_ok "Added ${name}"
}

add_vless_ws_tls() {
  local tag port name uuid preferred_domain host_domain ws_path cert_pair cert_file key_file node_json
  ensure_singbox_ready || return 1
  tag="$(generate_tag "vless-ws-tls")"
  port="$(prompt_port 8443)"
  name="$(prompt_with_default "Node name" "VLESS-WS-TLS")"
  read -r -p "UUID (leave blank to auto generate): " uuid
  uuid="${uuid:-$(generate_uuid)}"
  preferred_domain="$(prompt_with_default "Preferred domain" "${DEFAULT_CDN_DOMAIN}")"
  host_domain="$(prompt_with_default "Host/SNI domain" "${DEFAULT_TLS_SERVER}")"
  ws_path="$(prompt_with_default "WebSocket path" "$(random_ws_path)")"
  cert_pair="$(ensure_tls_material "$tag" "$host_domain")" || return 1
  cert_file="${cert_pair%|*}"
  key_file="${cert_pair#*|}"

  node_json="$(jq -n \
    --arg protocol "vless-ws-tls" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg uuid "$uuid" \
    --arg preferred_domain "$preferred_domain" \
    --arg host_domain "$host_domain" \
    --arg ws_path "$ws_path" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      uuid: $uuid,
      preferred_domain: $preferred_domain,
      host_domain: $host_domain,
      ws_path: $ws_path,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')"

  save_node "$tag" "$node_json"
  render_config && refresh_node_share_link "$tag" && start_service
  print_ok "Added ${name}"
}

add_anytls() {
  local tag port name password tls_server cert_pair cert_file key_file node_json
  ensure_singbox_ready || return 1
  tag="$(generate_tag "anytls")"
  port="$(prompt_port 5443)"
  name="$(prompt_with_default "Node name" "AnyTLS")"
  read -r -p "Password (leave blank to auto generate): " password
  password="${password:-$(generate_hex 8)}"
  tls_server="$(prompt_with_default "SNI domain" "${DEFAULT_TLS_SERVER}")"
  cert_pair="$(ensure_tls_material "$tag" "$tls_server")" || return 1
  cert_file="${cert_pair%|*}"
  key_file="${cert_pair#*|}"

  node_json="$(jq -n \
    --arg protocol "anytls" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg password "$password" \
    --arg tls_server "$tls_server" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      password: $password,
      tls_server: $tls_server,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')"

  save_node "$tag" "$node_json"
  render_config && refresh_node_share_link "$tag" && start_service
  print_ok "Added ${name}"
}

add_vless_argo() {
  local tag port name uuid preferred_domain ws_path argo_mode argo_token endpoint_domain node_json
  ensure_singbox_ready || return 1
  tag="$(generate_tag "vless-argo")"
  port="$(prompt_port 8001)"
  name="$(prompt_with_default "Node name" "VLESS-Argo")"
  read -r -p "UUID (leave blank to auto generate): " uuid
  uuid="${uuid:-$(generate_uuid)}"
  preferred_domain="$(prompt_with_default "Preferred domain" "${DEFAULT_CDN_DOMAIN}")"
  ws_path="$(prompt_with_default "WebSocket path" "$(random_ws_path)")"
  read -r -p "Use token tunnel? [y/N]: " argo_mode
  if [[ "$argo_mode" =~ ^[Yy]$ ]]; then
    argo_mode="token"
    argo_token="$(prompt_nonempty "Cloudflared tunnel token")"
    endpoint_domain="$(prompt_nonempty "Argo endpoint domain")"
  else
    argo_mode="temp"
    argo_token=""
    endpoint_domain=""
  fi

  node_json="$(jq -n \
    --arg protocol "vless-argo" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg uuid "$uuid" \
    --arg preferred_domain "$preferred_domain" \
    --arg ws_path "$ws_path" \
    --arg argo_mode "$argo_mode" \
    --arg argo_token "$argo_token" \
    --arg endpoint_domain "$endpoint_domain" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      uuid: $uuid,
      preferred_domain: $preferred_domain,
      ws_path: $ws_path,
      argo_mode: $argo_mode,
      argo_token: $argo_token,
      endpoint_domain: $endpoint_domain
    }')"

  save_node "$tag" "$node_json"
  render_config && refresh_node_share_link "$tag" && start_service
  start_argo_node "$tag"
  refresh_node_share_link "$tag"
  print_ok "Added ${name}"
}

add_tuic_v5() {
  local tag port name uuid password tls_server cert_pair cert_file key_file node_json
  ensure_singbox_ready || return 1
  tag="$(generate_tag "tuic-v5")"
  port="$(prompt_port 10443)"
  name="$(prompt_with_default "Node name" "TUIC-v5")"
  read -r -p "UUID (leave blank to auto generate): " uuid
  uuid="${uuid:-$(generate_uuid)}"
  read -r -p "Password (leave blank to auto generate): " password
  password="${password:-$uuid}"
  tls_server="$(prompt_with_default "SNI domain" "${DEFAULT_TLS_SERVER}")"
  cert_pair="$(ensure_tls_material "$tag" "$tls_server")" || return 1
  cert_file="${cert_pair%|*}"
  key_file="${cert_pair#*|}"

  node_json="$(jq -n \
    --arg protocol "tuic-v5" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg uuid "$uuid" \
    --arg password "$password" \
    --arg tls_server "$tls_server" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      uuid: $uuid,
      password: $password,
      tls_server: $tls_server,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')"

  save_node "$tag" "$node_json"
  render_config && refresh_node_share_link "$tag" && start_service
  print_ok "Added ${name}"
}

add_hy2() {
  local tag port name password tls_server cert_pair cert_file key_file node_json
  ensure_singbox_ready || return 1
  tag="$(generate_tag "hy2")"
  port="$(prompt_port 11443)"
  name="$(prompt_with_default "Node name" "Hysteria2")"
  read -r -p "Password (leave blank to auto generate): " password
  password="${password:-$(generate_hex 8)}"
  tls_server="$(prompt_with_default "SNI domain" "${DEFAULT_TLS_SERVER}")"
  cert_pair="$(ensure_tls_material "$tag" "$tls_server")" || return 1
  cert_file="${cert_pair%|*}"
  key_file="${cert_pair#*|}"

  node_json="$(jq -n \
    --arg protocol "hy2" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg password "$password" \
    --arg tls_server "$tls_server" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      password: $password,
      tls_server: $tls_server,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')"

  save_node "$tag" "$node_json"
  render_config && refresh_node_share_link "$tag" && start_service
  print_ok "Added ${name}"
}

add_socks5() {
  local tag port name username password node_json
  ensure_singbox_ready || return 1
  tag="$(generate_tag "socks5")"
  port="$(prompt_port 1080)"
  name="$(prompt_with_default "Node name" "SOCKS5")"
  username="$(prompt_with_default "Username" "user")"
  read -r -p "Password (leave blank to auto generate): " password
  password="${password:-$(generate_hex 6)}"

  node_json="$(jq -n \
    --arg protocol "socks5" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg username "$username" \
    --arg password "$password" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      username: $username,
      password: $password
    }')"

  save_node "$tag" "$node_json"
  render_config && refresh_node_share_link "$tag" && start_service
  print_ok "Added ${name}"
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
  echo "0. Back"
  echo
  read -r -p "Select: " choice
  case "$choice" in
    1) add_vless_reality ;;
    2) add_vless_ws_tls ;;
    3) add_anytls ;;
    4) add_vless_argo ;;
    5) add_tuic_v5 ;;
    6) add_hy2 ;;
    7) add_socks5 ;;
    0) return 0 ;;
    *) print_warn "Invalid choice." ;;
  esac
}

print_node_list() {
  local idx=1
  refresh_all_share_links
  while IFS=$'\t' read -r tag protocol name port share; do
    [ -n "$tag" ] || continue
    echo "${idx}. ${name} | ${protocol} | port: ${port}"
    echo "   tag: ${tag}"
    echo "   link: ${share}"
    idx=$((idx + 1))
  done < <(jq -r 'to_entries[] | [.key, .value.protocol, .value.name, (.value.port|tostring), (.value.share_link // "")] | @tsv' "${META_FILE}" 2>/dev/null)

  if [ "$idx" -eq 1 ]; then
    echo "No nodes found."
  fi
}

select_node_tag() {
  local -a rows
  local idx input
  mapfile -t rows < <(jq -r 'to_entries[] | [.key, .value.protocol, .value.name, (.value.port|tostring)] | @tsv' "${META_FILE}" 2>/dev/null)
  if [ "${#rows[@]}" -eq 0 ]; then
    print_warn "No nodes found."
    return 1
  fi

  idx=1
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r tag protocol name port <<< "$row"
    echo "${idx}. ${name} | ${protocol} | port: ${port}"
    idx=$((idx + 1))
  done

  read -r -p "Select node number: " input
  if ! [[ "$input" =~ ^[0-9]+$ ]] || [ "$input" -lt 1 ] || [ "$input" -gt "${#rows[@]}" ]; then
    print_warn "Invalid node selection."
    return 1
  fi

  IFS=$'\t' read -r tag _ <<< "${rows[$((input - 1))]}"
  printf '%s' "$tag"
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
  tag="$(select_node_tag)" || return 1
  protocol="$(jq -r --arg tag "$tag" '.[$tag].protocol' "${META_FILE}")"

  if ! confirm_yes "Delete node ${tag}?"; then
    return 0
  fi

  if [ "$protocol" = "vless-argo" ]; then
    stop_argo_node "$tag"
  fi

  cert_file="$(jq -r --arg tag "$tag" '.[$tag].certificate_path // empty' "${META_FILE}")"
  key_file="$(jq -r --arg tag "$tag" '.[$tag].key_path // empty' "${META_FILE}")"
  [ -n "$cert_file" ] && rm -f "$cert_file"
  [ -n "$key_file" ] && rm -f "$key_file"

  delete_node_key "$tag"
  render_config && start_service
  print_ok "Deleted ${tag}"
}

show_status() {
  local count
  init_storage
  detect_systemd
  count="$(jq 'length' "${META_FILE}" 2>/dev/null || printf '0')"
  echo
  echo "Project: ${PROJECT_NAME}"
  echo "Version: ${SCRIPT_VERSION}"
  echo "Service: $(service_state)"
  echo "Nodes: ${count}"
  if [ "${has_systemd}" = true ]; then
    echo "Watchdog timer: $(systemctl is-active ${WATCHDOG_TIMER_NAME} 2>/dev/null || echo unknown)"
  else
    echo "Watchdog: cron"
  fi
  echo
  print_node_list
  echo
}

restart_stack() {
  detect_systemd
  render_config || return 1
  start_service || return 1
  restart_all_argo_nodes || true
  refresh_all_share_links
}

update_script() {
  local tmp_script
  tmp_script="$(mktemp)"
  download_file "${RAW_BASE}/sb.sh" "${tmp_script}" || return 1
  install -m 0755 "${tmp_script}" "${INSTALL_BIN}"
  rm -f "${tmp_script}"
  copy_watchdog_asset || return 1
  print_ok "Script updated: ${INSTALL_BIN}"
}

uninstall_project() {
  if ! confirm_yes "This will remove ${PROJECT_NAME}. Continue"; then
    return 0
  fi

  detect_systemd
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    stop_argo_node "$tag"
  done < <(jq -r 'keys[]' "${META_FILE}" 2>/dev/null)

  stop_service || true

  if [ "${has_systemd}" = true ]; then
    systemctl disable --now "${WATCHDOG_TIMER_NAME}" >/dev/null 2>&1 || true
    systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
    rm -f "${SYSTEMD_SERVICE_FILE}" "${SYSTEMD_WATCHDOG_SERVICE_FILE}" "${SYSTEMD_WATCHDOG_TIMER_FILE}"
    systemctl daemon-reload || true
  elif command_exists crontab; then
    (crontab -l 2>/dev/null | grep -Fv "${WATCHDOG_TARGET}" || true) | crontab -
  fi

  rm -rf "${BASE_DIR}" "${INSTALL_BIN}" "${SINGBOX_BIN}" "${CLOUDFLARED_BIN}"
  print_ok "Project removed."
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
    echo "1. Install/Update core"
    echo "2. Add node"
    echo "3. View nodes"
    echo "4. Delete node"
    echo "5. Restart services"
    echo "6. Status"
    echo "7. Update script"
    echo "8. Uninstall"
    echo "0. Exit"
    echo
    read -r -p "Select: " choice
    case "$choice" in
      1) install_core ;;
      2) menu_add_node ;;
      3) list_nodes; read -r -p "Press Enter to continue..." _ ;;
      4) delete_node; read -r -p "Press Enter to continue..." _ ;;
      5) restart_stack; read -r -p "Press Enter to continue..." _ ;;
      6) show_status; read -r -p "Press Enter to continue..." _ ;;
      7) update_script; read -r -p "Press Enter to continue..." _ ;;
      8) uninstall_project; exit 0 ;;
      0) exit 0 ;;
      *) print_warn "Invalid choice."; sleep 1 ;;
    esac
  done
}

require_root
main_menu
