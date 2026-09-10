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
  local env_prefix=()
  if [ -n "${mem_limit}" ]; then
    env_prefix+=(GOMEMLIMIT="${mem_limit}")
  fi
  # P5：GOGC=off 在 standalone（无 systemd/openrc）场景同样生效
  if go_gc_requested; then
    env_prefix+=(GOGC="off")
  fi
  if [ "${#env_prefix[@]}" -gt 0 ]; then
    nohup env "${env_prefix[@]}" "${SINGBOX_BIN}" run -c "${CONFIG_FILE}" >>"${LOG_DIR}/sing-box.log" 2>&1 &
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
  local probe_fail_file probe_fail probe_fail_limit
  pid="$(read_pid_file "${PID_FILE}" 2>/dev/null || true)"
  # 存活且（/proc 可用时）确为 sing-box 实例才认为健康，防止 PID 复用导致漏重启
  if [ -n "${pid}" ] && pid_matches_binary_or_alive "${pid}" "${SINGBOX_BIN}"; then
    # S1：进程存活但所有节点端口均不可探测（数据面无响应）时视为假死，按失败计数重启
    if [ -f "${NODES_FILE}" ] && any_node_port_alive; then
      rm -f "${RUNTIME_DIR}/probe_fail_count"
      return 0
    fi
    if [ -f "${NODES_FILE}" ]; then
      local probe_fail
      probe_fail_file="${RUNTIME_DIR}/probe_fail_count"
      if [ -f "${probe_fail_file}" ]; then
        probe_fail="$(cat "${probe_fail_file}" 2>/dev/null | tr -dc '0-9' || true)"
      fi
      probe_fail="${probe_fail:-0}"
      probe_fail=$((probe_fail + 1))
      printf '%s' "${probe_fail}" >"${probe_fail_file}"
      chmod 600 "${probe_fail_file}"
      probe_fail_limit="${SBM_PROBE_FAIL_LIMIT:-3}"
      if [ "${probe_fail}" -lt "${probe_fail_limit}" ]; then
        print_warn "sing-box 端口探活失败 ${probe_fail}/${probe_fail_limit} 次，跳过本轮重启。"
        return 0
      fi
      rm -f "${probe_fail_file}"
      print_warn "sing-box 连续 ${probe_fail} 次探活失败，判定假死，强制重启。"
    else
      return 0
    fi
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

  : >"${log_file}"
  chmod 600 "${log_file}"
  # 截断（非追加）启动：日志只含本次进程内容，避免 parse_trycloudflare_domain
  # 从上一轮已死的 cloudflared 进程残留中误取旧域名（stale domain）。
  # 与 sb.sh start_argo_node 的 `: >` 语义一致。
  # 启动前清空旧域名：隧道失败时分享链接不再显示失效地址。
  # 用非阻塞 try_acquire_lock：watchdog 场景外层已释放锁，拿不到锁时
  # 跳过本轮写（与 watchdog 兜底语义一致），绝不在此阻塞占用 watch 周期。
  if ! try_acquire_lock; then
    print_warn "无法获取锁，跳过 ${tag} 的临时 Argo 域名清理。"
    return 1
  fi
  json_set_field "${NODES_FILE}" "${tag}" "endpoint_domain" "" 2>/dev/null || true
  release_lock
  edge_ip="$(argo_edge_ip_version)"
  # --protocol http2：压掉 QUIC 内存尖峰；追加模式写入（O_APPEND）避免轮转后稀疏文件
  nohup "${CLOUDFLARED_BIN}" tunnel --no-autoupdate --protocol http2 --edge-ip-version "${edge_ip}" --url "http://127.0.0.1:${local_port}" \
    >>"${log_file}" 2>&1 &
  write_pid_file "${pid_file}" "$!"

  # 域名需通过公共 DNS 发布确认（DoH）才写入节点，防止"看似成功实则不可解析"
  if domain="$(wait_for_trycloudflare_domain_verified "${log_file}" 60 1)"; then
    try_acquire_lock || {
      kill_pid_file "${pid_file}" "${CLOUDFLARED_BIN}"
      print_warn "写入 ${tag} 的临时 Argo 域名时无法获取锁，已保留隧道待下轮确认。"
      return 1
    }
    if jq -e --arg tag "$tag" 'has($tag)' "${NODES_FILE}" >/dev/null 2>&1; then
      if ! json_set_field "${NODES_FILE}" "${tag}" "endpoint_domain" "${domain}"; then
        kill_pid_file "${pid_file}" "${CLOUDFLARED_BIN}"
        print_warn "写入 ${tag} 的临时 Argo 域名失败。"
      fi
    else
      kill_pid_file "${pid_file}" "${CLOUDFLARED_BIN}"
    fi
    release_lock
  else
    kill_pid_file "${pid_file}" "${CLOUDFLARED_BIN}"
    try_acquire_lock || {
      print_warn "等待 ${tag} 的临时 Argo 域名超时，且无法获取锁清除旧域名。"
      return 1
    }
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

  : >"${log_file}"
  chmod 600 "${log_file}"
  edge_ip="$(argo_edge_ip_version)"
  # token 经环境变量传入，避免明文出现在进程命令行（ps 可见）
  TUNNEL_TOKEN="${token}" nohup "${CLOUDFLARED_BIN}" tunnel --no-autoupdate --protocol http2 --edge-ip-version "${edge_ip}" run \
    >>"${log_file}" 2>&1 &
  write_pid_file "${pid_file}" "$!"
}

ensure_argo_nodes() {
  local tag protocol mode pid_file pid
  local restarts last_restart now backoff restart_at_file
  [ -f "${NODES_FILE}" ] || return 0
  [ -x "${CLOUDFLARED_BIN}" ] || return 0

  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    protocol="$(node_value "$tag" "protocol")"
    [ "${protocol}" = "vless-argo" ] || continue

    pid_file="${RUNTIME_DIR}/${tag}.pid"
    pid="$(read_pid_file "${pid_file}" 2>/dev/null || true)"
    # 存活且（/proc 可用时）确为 cloudflared 实例才跳过重启，防止 PID 复用漏拉起
    if [ -n "${pid}" ] && pid_matches_binary_or_alive "${pid}" "${CLOUDFLARED_BIN}"; then
      # 隧道长时间稳定运行：清零崩溃计数，避免旧失败影响后续退避
      reset_restart_count "${tag}"
      continue
    fi

    # S2：崩溃退避——按 2^(n-1) 秒退避（封顶 30min），防止崩溃循环秒级重启风暴
    restarts="$(read_restart_count "$tag")"
    if [ "${restarts}" -gt 0 ]; then
      backoff="$(argo_backoff_delay "${restarts}")"
      restart_at_file="${RUNTIME_DIR}/${tag}.restart_at"
      if [ -f "${restart_at_file}" ]; then
        last_restart="$(cat "${restart_at_file}" 2>/dev/null | tr -dc '0-9' | head -c 12 || true)"
        last_restart="${last_restart:-0}"
        now="$(date +%s 2>/dev/null || echo 0)"
        if [ -n "${now}" ] && [ $((now - last_restart)) -lt "${backoff}" ]; then
          print_warn "节点 ${tag} 处于退避窗口（第 ${restarts} 次崩溃，${backoff}s 内不再重启）。"
          continue
        fi
      fi
    fi

    rm -f "${pid_file}"
    mode="$(node_value "$tag" "argo_mode")"
    if [ "${mode}" = "token" ]; then
      if start_token_tunnel "${tag}"; then
        bump_restart_count "${tag}"
        date +%s >"${RUNTIME_DIR}/${tag}.restart_at" 2>/dev/null || true
      fi
    else
      release_lock
      if start_temp_tunnel "${tag}"; then
        # 临时隧道启动即记录，成功与否由下轮域名核验/进程存活清空计数
        bump_restart_count "${tag}"
        date +%s >"${RUNTIME_DIR}/${tag}.restart_at" 2>/dev/null || true
      fi
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
apply_network_tune
ensure_singbox
ensure_argo_nodes
sanitize_permissions
release_lock
