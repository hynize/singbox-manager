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
  . "${LIB_DIR}/common.sh"
else
  . "${SCRIPT_DIR}/../lib/common.sh"
fi

setup_common_traps

has_systemd=false
has_openrc=false
if command_exists systemctl && [ -d /run/systemd/system ]; then
  has_systemd=true
elif command_exists rc-service && [ -x /sbin/openrc-run ]; then
  has_openrc=true
fi

start_non_systemd_singbox() {
  if [ ! -x "${SINGBOX_BIN}" ] || [ ! -f "${CONFIG_FILE}" ]; then
    return 0
  fi

  if ! "${SINGBOX_BIN}" check -c "${CONFIG_FILE}" >/dev/null 2>&1; then
    print_warn "配置校验失败，已跳过 sing-box 重启。"
    return 0
  fi

  rotate_log_file "${LOG_DIR}/sing-box.log" || true
  nohup "${SINGBOX_BIN}" run -c "${CONFIG_FILE}" >>"${LOG_DIR}/sing-box.log" 2>&1 &
  write_pid_file "${PID_FILE}" "$!"
}

ensure_log_rotation() {
  rotate_log_file "${LOG_DIR}/sing-box.log" || true
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

  if [ "${has_openrc}" = true ]; then
    if ! rc-service "${SERVICE_NAME}" status >/dev/null 2>&1; then
      kill_pid_file "${PID_FILE}"
      rc-service "${SERVICE_NAME}" restart >/dev/null 2>&1 || rc-service "${SERVICE_NAME}" start >/dev/null 2>&1 || true
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

require_root
init_storage
sanitize_permissions
acquire_lock
ensure_log_rotation
ensure_singbox
ensure_argo_nodes
sanitize_permissions
release_lock
