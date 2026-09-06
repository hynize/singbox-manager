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

require_bash4
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
  local mem_limit
  mem_limit="$(go_mem_limit_value)"
  if [ -n "${mem_limit}" ]; then
    nohup env GOMEMLIMIT="${mem_limit}" "${SINGBOX_BIN}" run -c "${CONFIG_FILE}" >>"${LOG_DIR}/sing-box.log" 2>&1 &
  else
    nohup "${SINGBOX_BIN}" run -c "${CONFIG_FILE}" >>"${LOG_DIR}/sing-box.log" 2>&1 &
  fi
  write_pid_file "${PID_FILE}" "$!"
}

ensure_log_rotation() {
  rotate_log_file "${LOG_DIR}/sing-box.log" || true
  # cloudflared 节点日志同样按大小轮转，防止长期运行无上限增长
  local lf
  while IFS= read -r lf; do
    [ -n "${lf}" ] || continue
    rotate_log_file "${lf}" || true
  done < <(find "${LOG_DIR}" -type f -name '*.cloudflared.log' 2>/dev/null)
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
      kill_pid_file "${PID_FILE}" "${SINGBOX_BIN}"
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

start_temp_tunnel() {
  local tag="$1"
  local local_port pid_file log_file domain edge_ip
  local_port="$(node_value "$tag" "port")"
  pid_file="${RUNTIME_DIR}/${tag}.pid"
  log_file="${LOG_DIR}/${tag}.cloudflared.log"

  : >>"${log_file}"
  chmod 600 "${log_file}"
  # 启动前清空旧域名：隧道失败时分享链接不再显示失效地址
  acquire_lock
  json_set_field "${NODES_FILE}" "${tag}" "endpoint_domain" "" 2>/dev/null || true
  release_lock
  edge_ip="$(argo_edge_ip_version)"
  # --protocol http2：压掉 QUIC 内存尖峰；追加模式写入（O_APPEND）避免轮转后稀疏文件
  nohup "${CLOUDFLARED_BIN}" tunnel --no-autoupdate --protocol http2 --edge-ip-version "${edge_ip}" --url "http://127.0.0.1:${local_port}" \
    >>"${log_file}" 2>&1 &
  write_pid_file "${pid_file}" "$!"

  # 域名需通过公共 DNS 发布确认（DoH）才写入节点，防止"看似成功实则不可解析"
  if domain="$(wait_for_trycloudflare_domain_verified "${log_file}" 60 1)"; then
    acquire_lock
    if jq -e --arg tag "$tag" 'has($tag)' "${NODES_FILE}" >/dev/null 2>&1; then
      if ! json_set_field "${NODES_FILE}" "${tag}" "endpoint_domain" "${domain}"; then
        kill_pid_file "${pid_file}"
        print_warn "写入 ${tag} 的临时 Argo 域名失败。"
      fi
    else
      kill_pid_file "${pid_file}"
    fi
    release_lock
  else
    kill_pid_file "${pid_file}"
    acquire_lock
    json_set_field "${NODES_FILE}" "${tag}" "endpoint_domain" "" 2>/dev/null || true
    release_lock
    print_warn "等待 ${tag} 的临时 Argo 域名超时（含 DNS 发布确认），已清除旧域名。"
  fi
}

start_token_tunnel() {
  local tag="$1"
  local token pid_file log_file edge_ip
  token="$(secret_value "$tag" "argo_token")"
  if [ -z "${token}" ]; then
    print_warn "节点 ${tag} 的 Argo Token 为空，已跳过启动。"
    return 0
  fi
  pid_file="${RUNTIME_DIR}/${tag}.pid"
  log_file="${LOG_DIR}/${tag}.cloudflared.log"

  : >>"${log_file}"
  chmod 600 "${log_file}"
  edge_ip="$(argo_edge_ip_version)"
  # token 经环境变量传入，避免明文出现在进程命令行（ps 可见）
  TUNNEL_TOKEN="${token}" nohup "${CLOUDFLARED_BIN}" tunnel --no-autoupdate --protocol http2 --edge-ip-version "${edge_ip}" run \
    >>"${log_file}" 2>&1 &
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
      start_token_tunnel "${tag}" || true
    else
      release_lock
      start_temp_tunnel "${tag}" || true
      try_acquire_lock || true
    fi
  done < <(iter_node_tags)
}

require_root
require_bash4
init_storage
sanitize_permissions
# 拿不到锁说明另一实例正在工作：静默跳过本轮，不报错
if ! try_acquire_lock; then
  exit 0
fi
ensure_log_rotation
reconcile_state || true
ensure_singbox
ensure_argo_nodes
sanitize_permissions
release_lock
