#!/usr/bin/env bash
set -uo pipefail

BASE_DIR="/usr/local/etc/singbox-manager"
CONFIG_FILE="${BASE_DIR}/config.json"
META_FILE="${BASE_DIR}/nodes.json"
LOG_DIR="${BASE_DIR}/logs"
RUNTIME_DIR="${BASE_DIR}/runtime"
SINGBOX_BIN="/usr/local/bin/sing-box"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
SERVICE_NAME="singbox-manager"

mkdir -p "${LOG_DIR}" "${RUNTIME_DIR}"

has_systemd=false
if command -v systemctl >/dev/null 2>&1; then
  has_systemd=true
fi

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

build_vless_argo_link() {
  local tag="$1"
  local public_domain actual_domain uuid ws_path name
  public_domain=$(jq -r --arg tag "$tag" '.[$tag].preferred_domain' "${META_FILE}")
  actual_domain=$(jq -r --arg tag "$tag" '.[$tag].endpoint_domain' "${META_FILE}")
  uuid=$(jq -r --arg tag "$tag" '.[$tag].uuid' "${META_FILE}")
  ws_path=$(jq -r --arg tag "$tag" '.[$tag].ws_path' "${META_FILE}")
  name=$(jq -r --arg tag "$tag" '.[$tag].name' "${META_FILE}")
  printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s#%s' \
    "$uuid" \
    "$public_domain" \
    "$actual_domain" \
    "$actual_domain" \
    "$(url_encode "$ws_path")" \
    "$(url_encode "$name")"
}

start_temp_tunnel() {
  local tag="$1"
  local local_port pid_file log_file domain
  local_port=$(jq -r --arg tag "$tag" '.[$tag].port' "${META_FILE}")
  pid_file="${RUNTIME_DIR}/${tag}.pid"
  log_file="${LOG_DIR}/${tag}.cloudflared.log"

  nohup "${CLOUDFLARED_BIN}" tunnel --no-autoupdate --edge-ip-version auto --url "http://127.0.0.1:${local_port}" \
    >"${log_file}" 2>&1 &
  echo $! > "${pid_file}"

  sleep 6
  domain="$(grep -aoE 'https://[-a-z0-9]+\.trycloudflare\.com' "${log_file}" | head -n 1 | sed 's#https://##')"
  if [ -n "${domain}" ]; then
    local tmp share_link
    share_link="$(build_vless_argo_link "$tag")"
    tmp="$(mktemp)"
    jq --arg tag "$tag" --arg domain "$domain" --arg share "$share_link" \
      '.[$tag].endpoint_domain = $domain | .[$tag].share_link = $share' "${META_FILE}" > "${tmp}" && mv "${tmp}" "${META_FILE}"
  fi
}

start_token_tunnel() {
  local tag="$1"
  local token pid_file log_file
  token=$(jq -r --arg tag "$tag" '.[$tag].argo_token' "${META_FILE}")
  pid_file="${RUNTIME_DIR}/${tag}.pid"
  log_file="${LOG_DIR}/${tag}.cloudflared.log"
  nohup "${CLOUDFLARED_BIN}" tunnel --no-autoupdate --edge-ip-version auto run --token "${token}" \
    >"${log_file}" 2>&1 &
  echo $! > "${pid_file}"
}

ensure_singbox() {
  if [ ! -x "${SINGBOX_BIN}" ] || [ ! -f "${CONFIG_FILE}" ]; then
    exit 0
  fi

  if [ "${has_systemd}" = true ]; then
    if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
      systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || true
    fi
  elif ! pgrep -f "${SINGBOX_BIN} run -c ${CONFIG_FILE}" >/dev/null 2>&1; then
    nohup "${SINGBOX_BIN}" run -c "${CONFIG_FILE}" >>"${LOG_DIR}/sing-box.log" 2>&1 &
  fi
}

ensure_argo_nodes() {
  [ -f "${META_FILE}" ] || exit 0
  [ -x "${CLOUDFLARED_BIN}" ] || exit 0

  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    local protocol mode pid_file pid
    protocol=$(jq -r --arg tag "$tag" '.[$tag].protocol' "${META_FILE}")
    [ "${protocol}" = "vless-argo" ] || continue
    mode=$(jq -r --arg tag "$tag" '.[$tag].argo_mode' "${META_FILE}")
    pid_file="${RUNTIME_DIR}/${tag}.pid"
    pid=""
    [ -f "${pid_file}" ] && pid="$(cat "${pid_file}" 2>/dev/null || true)"

    if [ -n "${pid}" ] && kill -0 "${pid}" >/dev/null 2>&1; then
      continue
    fi

    if [ "${mode}" = "token" ]; then
      start_token_tunnel "${tag}"
    else
      start_temp_tunnel "${tag}"
    fi
  done < <(jq -r 'keys[]' "${META_FILE}" 2>/dev/null)
}

ensure_singbox
ensure_argo_nodes
