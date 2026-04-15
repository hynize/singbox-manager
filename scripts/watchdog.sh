#!/usr/bin/env bash
set -eEuo pipefail

umask 077

BASE_DIR="/usr/local/etc/singbox-manager"
LIB_DIR="/usr/local/lib/singbox-manager"
SINGBOX_BIN="/usr/local/bin/sing-box"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
CONFIG_FILE="${BASE_DIR}/config.json"
RUNTIME_DIR="${BASE_DIR}/runtime"
LOG_DIR="${BASE_DIR}/logs"
SERVICE_NAME="singbox-manager"
PID_FILE="${RUNTIME_DIR}/sing-box.pid"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${LIB_DIR}/common.sh" ]; then
  # shellcheck source=../lib/common.sh
  . "${LIB_DIR}/common.sh"
else
  # shellcheck source=../lib/common.sh
  . "${SCRIPT_DIR}/../lib/common.sh"
fi

setup_common_traps

has_systemd=false
if command_exists systemctl && [ -d /run/systemd/system ]; then
  has_systemd=true
fi

start_non_systemd_singbox() {
  if [ ! -x "${SINGBOX_BIN}" ] || [ ! -f "${CONFIG_FILE}" ]; then
    return 0
  fi

  if ! "${SINGBOX_BIN}" check -c "${CONFIG_FILE}" >/dev/null 2>&1; then
    print_warn "Skipping sing-box restart because config validation failed."
    return 0
  fi

  nohup "${SINGBOX_BIN}" run -c "${CONFIG_FILE}" >>"${LOG_DIR}/sing-box.log" 2>&1 &
  write_pid_file "${PID_FILE}" "$!"
}

ensure_singbox() {
  if [ ! -x "${SINGBOX_BIN}" ] || [ ! -f "${CONFIG_FILE}" ]; then
    return 0
  fi

  if [ "${has_systemd}" = true ]; then
    if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
      systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || true
    fi
    return 0
  fi

  local pid
  pid="$(read_pid_file "${PID_FILE}" 2>/dev/null || true)"
  if [ -n "${pid}" ] && kill -0 "${pid}" >/dev/null 2>&1; then
    return 0
  fi

  rm -f "${PID_FILE}"
  start_non_systemd_singbox
}

start_temp_tunnel() {
  local tag="$1"
  local local_port pid_file log_file domain
  local_port="$(node_value "$tag" "port")"
  pid_file="${RUNTIME_DIR}/${tag}.pid"
  log_file="${LOG_DIR}/${tag}.cloudflared.log"

  : > "${log_file}"
  chmod 600 "${log_file}"
  nohup "${CLOUDFLARED_BIN}" tunnel --no-autoupdate --edge-ip-version auto --url "http://127.0.0.1:${local_port}" \
    >"${log_file}" 2>&1 &
  write_pid_file "${pid_file}" "$!"

  if domain="$(wait_for_trycloudflare_domain "${log_file}" 60 2)"; then
    json_set_field "${NODES_FILE}" "${tag}" "endpoint_domain" "${domain}"
  else
    print_warn "Timed out waiting for temporary Argo domain for ${tag}"
  fi
}

start_token_tunnel() {
  local tag="$1"
  local token pid_file log_file
  token="$(secret_value "$tag" "argo_token")"
  pid_file="${RUNTIME_DIR}/${tag}.pid"
  log_file="${LOG_DIR}/${tag}.cloudflared.log"

  : > "${log_file}"
  chmod 600 "${log_file}"
  nohup "${CLOUDFLARED_BIN}" tunnel --no-autoupdate --edge-ip-version auto run --token "${token}" \
    >"${log_file}" 2>&1 &
  write_pid_file "${pid_file}" "$!"
}

ensure_argo_nodes() {
  local tag protocol mode pid_file pid
  [ -f "${NODES_FILE}" ] || return 0
  [ -x "${CLOUDFLARED_BIN}" ] || return 0

  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    protocol="$(node_value "$tag" "protocol")"
    [ "${protocol}" = "vless-argo" ] || continue

    pid_file="${RUNTIME_DIR}/${tag}.pid"
    pid="$(read_pid_file "${pid_file}" 2>/dev/null || true)"
    if [ -n "${pid}" ] && kill -0 "${pid}" >/dev/null 2>&1; then
      continue
    fi

    rm -f "${pid_file}"
    mode="$(node_value "$tag" "argo_mode")"
    if [ "${mode}" = "token" ]; then
      start_token_tunnel "${tag}"
    else
      start_temp_tunnel "${tag}"
    fi
  done < <(iter_node_tags)
}

require_root
init_storage
sanitize_permissions
acquire_lock
ensure_singbox
ensure_argo_nodes
sanitize_permissions
release_lock
