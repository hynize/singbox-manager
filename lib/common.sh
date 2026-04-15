#!/usr/bin/env bash
set -eEuo pipefail

umask 077

PROJECT_NAME="${PROJECT_NAME:-Singbox Manager}"
BASE_DIR="${BASE_DIR:-/usr/local/etc/singbox-manager}"
LIB_DIR="${LIB_DIR:-/usr/local/lib/singbox-manager}"
CONFIG_FILE="${CONFIG_FILE:-${BASE_DIR}/config.json}"
NODES_FILE="${NODES_FILE:-${BASE_DIR}/nodes.json}"
SECRETS_FILE="${SECRETS_FILE:-${BASE_DIR}/secrets.json}"
CERT_DIR="${CERT_DIR:-${BASE_DIR}/certs}"
LOG_DIR="${LOG_DIR:-${BASE_DIR}/logs}"
RUNTIME_DIR="${RUNTIME_DIR:-${BASE_DIR}/runtime}"
LOCK_FILE="${LOCK_FILE:-${BASE_DIR}/.lock}"
LOCK_TIMEOUT="${LOCK_TIMEOUT:-30}"

SINGBOX_BIN="${SINGBOX_BIN:-/usr/local/bin/sing-box}"
CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-/usr/local/bin/cloudflared}"
SERVICE_NAME="${SERVICE_NAME:-singbox-manager}"

COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_RED="\033[1;31m"
COLOR_BLUE="\033[1;34m"
COLOR_RESET="\033[0m"

LOCK_HELD=false
LOCK_FD=""
LOCK_DIR_FALLBACK="${LOCK_FILE}.d"

print_ok() {
  echo -e "${COLOR_GREEN}[OK]${COLOR_RESET} $*"
}

print_warn() {
  echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*" >&2
}

print_err() {
  echo -e "${COLOR_RED}[ERR]${COLOR_RESET} $*" >&2
}

print_info() {
  echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"
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
    fatal "Please run as root."
  fi
}

setup_common_traps() {
  trap 'release_lock' EXIT INT TERM
  trap 'handle_common_error "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}" "${BASH_LINENO[0]:-0}" "$?"' ERR
}

handle_common_error() {
  local source_file="$1"
  local line_no="$2"
  local exit_code="$3"
  print_err "Command failed at ${source_file}:${line_no}"
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
    fatal "curl or wget is required."
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
    fatal "SHA256 mismatch for ${target}: expected ${expected}, got ${actual}"
  fi
}

ensure_dir_mode() {
  local dir="$1"
  local mode="$2"
  install -d -m "$mode" "$dir"
}

ensure_file_mode() {
  local file="$1"
  local mode="$2"
  local default_content="${3:-}"
  if [ ! -f "$file" ]; then
    printf '%s' "$default_content" > "$file"
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
    exec {LOCK_FD}> "${LOCK_FILE}"
    if ! flock -w "${LOCK_TIMEOUT}" "${LOCK_FD}"; then
      fatal "Could not acquire lock within ${LOCK_TIMEOUT}s"
    fi
  else
    while ! mkdir "${LOCK_DIR_FALLBACK}" 2>/dev/null; do
      now="$(date +%s)"
      if [ $((now - start_time)) -ge "${LOCK_TIMEOUT}" ]; then
        fatal "Could not acquire lock within ${LOCK_TIMEOUT}s"
      fi
      sleep 1
    done
  fi

  LOCK_HELD=true
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
  jq "$@" "$file" > "${tmp}"
  chmod 600 "${tmp}"
  mv "${tmp}" "$file"
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
  jq -r --arg tag "$tag" --arg field "$field" '.[$tag][$field] // empty' "$file"
}

node_value() {
  record_value "${NODES_FILE}" "$1" "$2"
}

secret_value() {
  record_value "${SECRETS_FILE}" "$1" "$2"
}

iter_node_tags() {
  jq -r 'keys[]' "${NODES_FILE}" 2>/dev/null
}

delete_node_records() {
  local tag="$1"
  json_delete_record "${NODES_FILE}" "$tag"
  json_delete_record "${SECRETS_FILE}" "$tag"
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

  if ! openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$key_file" \
    -out "$cert_file" \
    -subj "/CN=${domain}" \
    -addext "subjectAltName=${san}" >/dev/null 2>&1; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -keyout "$key_file" \
      -out "$cert_file" \
      -subj "/CN=${domain}" >/dev/null 2>&1
  fi

  chmod 600 "$cert_file" "$key_file"
  printf '%s|%s' "$cert_file" "$key_file"
}

parse_trycloudflare_domain() {
  local log_file="$1"
  grep -aoE 'https://[-a-z0-9]+\.trycloudflare\.com' "$log_file" 2>/dev/null | tail -n 1 | sed 's#https://##'
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

write_pid_file() {
  local pid_file="$1"
  local pid="$2"
  printf '%s\n' "$pid" > "$pid_file"
  chmod 600 "$pid_file"
}

read_pid_file() {
  local pid_file="$1"
  [ -f "$pid_file" ] || return 1
  tr -d '\r\n' < "$pid_file"
}

kill_pid_file() {
  local pid_file="$1"
  local pid=""
  pid="$(read_pid_file "$pid_file" 2>/dev/null || true)"
  if [ -n "$pid" ]; then
    kill "$pid" >/dev/null 2>&1 || true
  fi
  rm -f "$pid_file"
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
      reality_server="$(node_value "$tag" "reality_server")"
      public_key="$(node_value "$tag" "public_key")"
      short_id="$(node_value "$tag" "short_id")"
      printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
        "$uuid" "$host" "$port" "$reality_server" "$public_key" "$short_id" "$(url_encode "$name")"
      ;;
    vless-ws-tls)
      uuid="$(secret_value "$tag" "uuid")"
      ws_path="$(node_value "$tag" "ws_path")"
      preferred_domain="$(node_value "$tag" "preferred_domain")"
      host_domain="$(node_value "$tag" "host_domain")"
      cert_mode="$(node_value "$tag" "certificate_mode")"
      printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s' \
        "$uuid" "$(wrap_host "$preferred_domain")" "$port" "$host_domain" "$host_domain" "$(url_encode "$ws_path")"
      if [ "$cert_mode" = "self-signed" ]; then
        printf '&allowInsecure=1'
      fi
      printf '#%s' "$(url_encode "$name")"
      ;;
    anytls)
      password="$(secret_value "$tag" "password")"
      tls_server="$(node_value "$tag" "tls_server")"
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
      [ -n "$endpoint_domain" ] || endpoint_domain="pending.example.com"
      printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s#%s' \
        "$uuid" "$(wrap_host "$preferred_domain")" "$endpoint_domain" "$endpoint_domain" "$(url_encode "$ws_path")" "$(url_encode "$name")"
      ;;
    tuic-v5)
      uuid="$(secret_value "$tag" "uuid")"
      password="$(secret_value "$tag" "password")"
      tls_server="$(node_value "$tag" "tls_server")"
      printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&alpn=h3&sni=%s&allow_insecure=1&allowInsecure=1#%s' \
        "$uuid" "$(url_encode "$password")" "$host" "$port" "$tls_server" "$(url_encode "$name")"
      ;;
    hy2)
      password="$(secret_value "$tag" "password")"
      tls_server="$(node_value "$tag" "tls_server")"
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
