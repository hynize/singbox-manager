#!/usr/bin/env bash
# shellcheck disable=SC2016
set -eEuo pipefail

# 函数级冒烟测试：source sb.sh（SBM_TEST_MODE=1 阻止入口执行），
# 在临时目录中验证纯逻辑函数，不安装二进制、不触碰 systemd。
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${TESTS_DIR}/.." && pwd)"

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "${desc}" "${expected}" "${actual}" >&2
  fi
}

assert_eval_true() {
  if eval "$2" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL (应为真): %s\n' "$1" >&2
  fi
}

assert_eval_false() {
  if eval "$2" >/dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    printf 'FAIL (应为假): %s\n' "$1" >&2
  else
    PASS=$((PASS + 1))
  fi
}

# Windows (Git Bash/MSYS) 下使用 C:/ 风格路径作为沙箱，避免 native 二进制
# (openssl/jq) 与 MSYS 路径转换互相破坏；Linux 仍用 mktemp。
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*)
  base_tmp="${LOCALAPPDATA:-${TEMP:-C:/Temp}}"
  TEST_ROOT="$(cygpath -m "${base_tmp}")/sbm-smoke-$$"
  mkdir -p "${TEST_ROOT}"
  ;;
*)
  TEST_ROOT="$(mktemp -d)"
  ;;
esac
export BASE_DIR="${TEST_ROOT}/etc"
export LIB_DIR="${TEST_ROOT}/lib"
export INSTALL_BIN="${TEST_ROOT}/sbm"
export PUBLIC_IP_CACHE="203.0.113.10"
export SBM_TEST_MODE=1
# MSYS 下禁用参数路径转换：沙箱路径已是 C:/ 风格无需转换，
# 同时防止 -subj "/CN=..." 被误转换（Linux 上这些变量无效果）
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*) export MSYS2_ARG_CONV_EXCL="*" MSYS_NO_PATHCONV=1 ;;
esac

# shellcheck source=../sb.sh
source "${ROOT_DIR}/sb.sh"

# --- normalize_input ---
assert_eq "normalize_input 去首尾空白" "hello" "$(normalize_input "  hello  ")"
assert_eq "normalize_input 删除控制字符" "abcd" "$(normalize_input "$(printf 'ab\tc\rd')")"

# --- 端口与环境变量解析 ---
assert_eval_true "env_port 合法端口" 'vlrt=2083; [ "$(env_port vlrt)" = "2083" ]'
assert_eval_false "env_port 非法端口" 'vlrt=abc; env_port vlrt'
assert_eval_false "env_port 端口越界" 'vlrt=70000; env_port vlrt'
assert_eval_false "env_port 未设置" 'unset vlrt; env_port vlrt'
assert_eval_true "auto_has_node_env 有 vlrt" 'vlrt=2083; auto_has_node_env'
assert_eval_true "auto_has_node_env 有 argo" 'argo=vlpt; auto_has_node_env'
assert_eval_false "auto_has_node_env 全空" 'unset vlrt wspt tupt anypt hypt socks5pt argo; auto_has_node_env'
assert_eval_true "auto_argo_requested vlpt" 'argo=vlpt; auto_argo_requested'
assert_eval_false "auto_argo_requested trpt" 'argo=trpt; auto_argo_requested'
assert_eval_false "auto_argo_requested 未设置" 'unset argo; auto_argo_requested'
assert_eval_true "auto_positive_or_default 合法" 'up_mbps=500; [ "$(auto_positive_or_default up_mbps 200)" = "500" ]'
assert_eval_true "auto_positive_or_default 非法回退" 'up_mbps=abc; [ "$(auto_positive_or_default up_mbps 200)" = "200" ]'

# --- IP 工具 ---
assert_eval_true "is_ip_address IPv4" 'is_ip_address 1.2.3.4'
assert_eval_true "is_ip_address IPv6" 'is_ip_address 2001:db8::1'
assert_eval_false "is_ip_address 域名" 'is_ip_address example.com'
assert_eval_true "is_private_ip 10段" 'is_private_ip 10.0.0.1'
assert_eval_true "is_private_ip 172.16段" 'is_private_ip 172.16.0.1'
assert_eval_false "is_private_ip 172.32段" 'is_private_ip 172.32.0.1'
assert_eval_false "is_private_ip 公网" 'is_private_ip 8.8.8.8'
assert_eq "wrap_host IPv6 加括号" "[::1]" "$(wrap_host "::1")"
assert_eq "wrap_host IPv4 原样" "1.2.3.4" "$(wrap_host "1.2.3.4")"
assert_eq "get_public_ip 使用缓存" "203.0.113.10" "$(get_public_ip)"

# --- 存储初始化与 JSON 读写 ---
init_storage
assert_eval_true "init_storage 建立目录" '[ -d "${CERT_DIR}" ] && [ -d "${RUNTIME_DIR}" ]'
assert_eq "nodes.json 权限 600" "600" "$(stat -c %a "${NODES_FILE}")"

json_set_record "${NODES_FILE}" "n1" '{"protocol":"vless-reality","name":"VLESS-Reality","port":443,"public_key":"pbk_test","short_id":"abcd"}'
json_set_record "${SECRETS_FILE}" "n1" '{"uuid":"uuid-1111","private_key":"priv_test"}'
assert_eq "node_value 读取协议" "vless-reality" "$(node_value n1 protocol)"
assert_eq "secret_value 读取 uuid" "uuid-1111" "$(secret_value n1 uuid)"
json_set_field "${NODES_FILE}" "n1" "endpoint_domain" "demo.example.com"
assert_eq "json_set_field 写入字段" "demo.example.com" "$(node_value n1 endpoint_domain)"

# --- 分享链接 ---
assert_eval_true "Reality 链接含 reality 参数" 'build_share_link n1 | grep -q "security=reality"'
assert_eval_true "Reality 链接含缓存公网 IP" 'build_share_link n1 | grep -q "203.0.113.10:443"'

json_set_record "${NODES_FILE}" "n2" '{"protocol":"hy2","name":"Hysteria2","port":11443,"tls_server":"www.bing.com","certificate_mode":"self-signed"}'
json_set_record "${SECRETS_FILE}" "n2" '{"password":"pw123"}'
assert_eval_true "hy2 自签链接含 insecure=1" 'build_share_link n2 | grep -q "insecure=1"'

json_set_record "${NODES_FILE}" "n3" '{"protocol":"socks5","name":"SOCKS5","port":1080,"username":"user"}'
json_set_record "${SECRETS_FILE}" "n3" '{"password":"pw456"}'
assert_eval_true "socks5 链接含用户名密码" 'build_share_link n3 | grep -q "user:pw456@"'

# --- 自签证书与回退逻辑 ---
assert_eval_true "ensure_tls_material 生成证书" 'pair="$(ensure_tls_material tag_tls www.bing.com)"; [ -f "${pair%|*}" ] && [ -f "${pair#*|}" ]'
assert_eval_true "auto_cert_bundle 默认自签" 'auto_cert_bundle t_auto www.bing.com | grep -q "^self-signed|"'
assert_eval_false "auto_cert_bundle custom 缺路径回退自签" 'unset cert_path key_path; cert=custom; auto_cert_bundle t_c www.bing.com | grep -q "^custom|"'

# --- wipe_records ---
wipe_records
assert_eq "wipe_records 清空 nodes" "0" "$(jq length "${NODES_FILE}")"
assert_eq "wipe_records 清空 secrets" "0" "$(jq length "${SECRETS_FILE}")"

# --- 日志轮转 ---
big_file="${TEST_ROOT}/big.log"
head -c 2048 /dev/zero >>"${big_file}"
LOG_ROTATE_SIZE_MB=0 rotate_log_file "${big_file}" || true
assert_eval_true "rotate_log_file 产生轮转文件" '[ -f "${big_file}.1" ]'

# --- CLI 用法输出 ---
assert_eval_true "print_cli_usage 可执行" 'print_cli_usage | grep -q "用法"'

# ---------------------------------------------------------------------------
# 一键安装（auto_install）端到端模拟：stub sing-box 二进制，覆盖 6 种协议
# ---------------------------------------------------------------------------
STUB_BIN="${TEST_ROOT}/bin"
mkdir -p "${STUB_BIN}"
cat >"${STUB_BIN}/sing-box" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
version) echo "sing-box version 1.13.16" ;;
check) exit 0 ;;
run) sleep 300 ;;
generate)
  shift
  if [ "${1:-}" = "reality-keypair" ]; then
    printf 'PrivateKey: %s\n' "$(openssl rand -base64 32 | tr -d '\n')"
    printf 'PublicKey: %s\n' "$(openssl rand -base64 32 | tr -d '\n')"
    exit 0
  fi
  exit 1
  ;;
*) exit 0 ;;
esac
EOF
chmod 0755 "${STUB_BIN}/sing-box"
export SINGBOX_BIN="${STUB_BIN}/sing-box"

export vlrt=20831 wspt=20835 anypt=20834 tupt=20833 hypt=20832 socks5pt=20836
export name=HK uuid=11111111-2222-3333-4444-555555555555 passwd=testpw
export cdn_host=cdn.example.com ws_host=ws.example.com ws_path=/wspath
export vl_sni=www.apple.com tu_sni=tu.example.com any_sni=any.example.com hy_sni=hy.example.com
export up_mbps=100 down_mbps=300 socks5_username=u1 socks5_password=p1

assert_eval_true "一键安装 6 协议成功" '( auto_install ins )'
assert_eq "一键安装写入 6 个节点" "6" "$(jq length "${NODES_FILE}")"
assert_eq "config 生成 6 个 inbound" "6" "$(jq '.inbounds | length' "${CONFIG_FILE}")"
assert_eval_true "Reality inbound 正确" 'jq -e ".inbounds[] | select(.type == \"vless\" and .tls.reality.enabled == true)" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "TUIC inbound 正确" 'jq -e ".inbounds[] | select(.type == \"tuic\")" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "HY2 inbound 带宽生效" 'jq -e ".inbounds[] | select(.type == \"hysteria2\" and .up_mbps == 100)" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "WS inbound 路径生效" 'jq -e ".inbounds[] | select(.transport.path == \"/wspath\")" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "SOCKS5 inbound 用户生效" 'jq -e ".inbounds[] | select(.type == \"socks\" and .users[0].username == \"u1\")" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "vless 使用指定 uuid" 'jq -e ".inbounds[].users[]? | select(.uuid == \"11111111-2222-3333-4444-555555555555\")" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "sing-box stub 已启动" 'pid="$(read_pid_file "${PID_FILE}")"; [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null'

# 重复 ins：端口已被现有节点占用，全部跳过 → added=0 退出码 1（子 shell 中运行以捕获 exit）
assert_eval_false "重复 ins 端口冲突时拒绝" '( auto_install ins )'

# rep：清空后按新端口重建（先 unset 其余协议端口）
unset wspt anypt tupt socks5pt
export vlrt=21831 hypt=21832
assert_eval_true "rep 重建成功" '( auto_install rep )'
assert_eq "rep 后只剩新节点" "2" "$(jq length "${NODES_FILE}")"
assert_eq "rep 后 config 为 2 个 inbound" "2" "$(jq '.inbounds | length' "${CONFIG_FILE}")"

# 清理 stub 进程
kill_pid_file "${PID_FILE}" || true

rm -rf "${TEST_ROOT}"

echo
echo "冒烟测试结果：通过 ${PASS}，失败 ${FAIL}"
if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
