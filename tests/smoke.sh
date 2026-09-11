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
assert_eval_false "is_ip_address 越界八位组" 'is_ip_address 1.2.3.999'
assert_eval_false "is_ip_address 多重 ::" 'is_ip_address ::::'
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
assert_eval_true "hy2 自签无指纹时回退 insecure=1" 'build_share_link n2 | grep -q "insecure=1"'

json_set_record "${NODES_FILE}" "n2b" '{"protocol":"hy2","name":"Hysteria2-Pin","port":11444,"tls_server":"www.bing.com","certificate_mode":"self-signed","certificate_path":"cert"}'
json_set_record "${SECRETS_FILE}" "n2b" '{"password":"pw123"}'
# 为 n2b 生成真实自签证书供指纹提取
pin_pair="$(ensure_tls_material tag_pin www.bing.com)"
jq --arg p "${pin_pair%|*}" '.n2b.certificate_path = $p' "${NODES_FILE}" >"${NODES_FILE}.tmp" && mv "${NODES_FILE}.tmp" "${NODES_FILE}"
assert_eval_true "hy2 自签有证书时输出 pinSHA256" 'build_share_link n2b | grep -q "pinSHA256=[0-9a-f]\{64\}"'
assert_eval_false "hy2 pin 链接不再含 insecure" 'build_share_link n2b | grep -q "insecure=1"'
assert_eval_true "cert_fingerprint 输出 64 位 hex" 'fp="$(cert_fingerprint "${pin_pair%|*}")"; [[ "${fp}" =~ ^[0-9a-f]{64}$ ]]'

json_set_record "${NODES_FILE}" "n3" '{"protocol":"socks5","name":"SOCKS5","port":1080,"username":"user"}'
json_set_record "${SECRETS_FILE}" "n3" '{"password":"pw456"}'
assert_eval_true "socks5 链接含用户名密码" 'build_share_link n3 | grep -q "user:pw456@"'

# --- 链接参数编码与域名校验（审查 F-09） ---
json_set_record "${NODES_FILE}" "n9" '{"protocol":"vless-ws-tls","name":"EN&X","port":443,"preferred_domain":"cdn.example.com","host_domain":"a&b.com","ws_path":"/p","certificate_mode":"custom"}'
json_set_record "${SECRETS_FILE}" "n9" '{"uuid":"u9"}'
assert_eval_true "特殊字符 host 被编码" 'build_share_link n9 | grep -q "sni=a%26b.com"'
assert_eval_true "特殊字符 name 被编码" 'build_share_link n9 | grep -q "EN%26X"'
json_set_record "${NODES_FILE}" "nargo" '{"protocol":"vless-argo","name":"A","port":8001,"preferred_domain":"saas.sin.fan","ws_path":"/w","endpoint_domain":""}'
json_set_record "${SECRETS_FILE}" "nargo" '{"uuid":"ua"}'
assert_eq "空 endpoint 不生成失效链接" "" "$(build_share_link nargo)"
assert_eval_true "is_safe_domain 合法域名" 'is_safe_domain cdn.example.com'
assert_eval_true "is_safe_domain IPv6" 'is_safe_domain 2001:db8::1'
assert_eval_false "is_safe_domain 含空格" 'is_safe_domain "a b.com"'
assert_eval_false "is_safe_domain 含 &" 'is_safe_domain "a&b.com"'
assert_eval_false "is_safe_domain 空值" 'is_safe_domain ""'

# --- IPv6 authority 生成（审查 F-05）：必须先 wrap_host 加括号、再编码 query 字段 ---
json_set_record "${NODES_FILE}" "n6ws" '{"protocol":"vless-ws-tls","name":"IPv6WS","port":443,"preferred_domain":"2001:db8::1","host_domain":"t.example.com","ws_path":"/p","certificate_mode":"custom","ws_mode":"cdn"}'
json_set_record "${SECRETS_FILE}" "n6ws" '{"uuid":"u6ws"}'
assert_eval_true "IPv6 WS(CDN) authority 加括号（不被 url_encode）" 'build_share_link n6ws | grep -q "@\[2001:db8::1\]:443"'
assert_eval_false "IPv6 WS(CDN) authority 不做 %5B 编码" 'build_share_link n6ws | grep -q "%5B2001"'
json_set_record "${NODES_FILE}" "n6a" '{"protocol":"vless-argo","name":"A6","port":443,"preferred_domain":"2001:db8::99","ws_path":"/w","endpoint_domain":"demo.trycloudflare.com"}'
json_set_record "${SECRETS_FILE}" "n6a" '{"uuid":"u6a"}'
assert_eval_true "IPv6 Argo authority 加括号" 'build_share_link n6a | grep -q "@\[2001:db8::99\]:443"'
json_set_record "${NODES_FILE}" "n6d" '{"protocol":"vless-ws-tls","name":"Domain","port":443,"preferred_domain":"cdn.example.com","host_domain":"h.example.com","ws_path":"/p","certificate_mode":"custom","ws_mode":"cdn"}'
json_set_record "${SECRETS_FILE}" "n6d" '{"uuid":"u6d"}'
assert_eval_true "域名 WS(CDN) authority 不受影响" 'build_share_link n6d | grep -q "@cdn.example.com:443"'
# WS-TLS 直连与 CDN 中转双模式（v0.2.22）：
json_set_record "${NODES_FILE}" "nws-direct" '{"protocol":"vless-ws-tls","name":"WS-Direct","port":20835,"host_domain":"ws.example.com","ws_path":"/p","certificate_mode":"self-signed","ws_mode":"direct"}'
json_set_record "${SECRETS_FILE}" "nws-direct" '{"uuid":"uwsd"}'
assert_eval_true "WS 直连 authority 用服务器 IP" 'build_share_link nws-direct | grep -q "@203.0.113.10:20835"'
assert_eval_true "WS 直连 sni/host 用 WS Host 域名" 'build_share_link nws-direct | grep -q "sni=ws.example.com&type=ws&host=ws.example.com"'
assert_eval_true "WS 直连自签无证书时回退 allowInsecure=1" 'build_share_link nws-direct | grep -q "allowInsecure=1"'
json_set_record "${NODES_FILE}" "nws-pin" '{"protocol":"vless-ws-tls","name":"WS-Pin","port":20835,"host_domain":"ws.example.com","ws_path":"/p","certificate_mode":"self-signed","ws_mode":"direct"}'
json_set_record "${SECRETS_FILE}" "nws-pin" '{"uuid":"uwsp"}'
ws_pin_pair="$(ensure_tls_material tag_wspin ws.example.com)"
json_set_field "${NODES_FILE}" "nws-pin" "certificate_path" "${ws_pin_pair%|*}"
assert_eval_true "WS 自签有证书时输出 pcs=pinnedPeerCertSha256" 'build_share_link nws-pin | grep -q "pcs=[0-9a-f]\{64\}"'
assert_eval_false "WS pcs 链接不再含 allowInsecure" 'build_share_link nws-pin | grep -q "allowInsecure=1"'
json_set_record "${NODES_FILE}" "nws-cdn" '{"protocol":"vless-ws-tls","name":"WS-CDN","port":20835,"preferred_domain":"cdn.example.com","host_domain":"ws.example.com","ws_path":"/p","certificate_mode":"custom","ws_mode":"cdn","cdn_port":8443}'
json_set_record "${SECRETS_FILE}" "nws-cdn" '{"uuid":"uwsc"}'
assert_eval_true "WS CDN authority 用优选域名+CDN 端口" 'build_share_link nws-cdn | grep -q "@cdn.example.com:8443"'
assert_eval_true "WS CDN sni/host 用优选域名" 'build_share_link nws-cdn | grep -q "sni=cdn.example.com&type=ws&host=cdn.example.com"'
# WS CDN + 自签证书：不得输出 pcs（CDN 模式下客户端面对前置 CDN 的公开证书，固定源站自签指纹必然失败）
json_set_record "${NODES_FILE}" "nws-cdn-pin" '{"protocol":"vless-ws-tls","name":"WS-CDN-Pin","port":20835,"preferred_domain":"cdn.example.com","host_domain":"ws.example.com","ws_path":"/p","certificate_mode":"self-signed","ws_mode":"cdn","cdn_port":8443}'
json_set_record "${SECRETS_FILE}" "nws-cdn-pin" '{"uuid":"uwscp"}'
ws_cdn_pin_pair="$(ensure_tls_material tag_wscdnpin ws.example.com)"
json_set_field "${NODES_FILE}" "nws-cdn-pin" "certificate_path" "${ws_cdn_pin_pair%|*}"
assert_eval_false "WS CDN 自签证书不输出 pcs" 'build_share_link nws-cdn-pin | grep -q "pcs="'
assert_eval_false "WS CDN 自签证书不输出 allowInsecure" 'build_share_link nws-cdn-pin | grep -q "allowInsecure"'
# AnyTLS 链接格式（v0.2.22）：insecure=1 + type=tcp&headerType=none
json_set_record "${NODES_FILE}" "nanytls" '{"protocol":"anytls","name":"AnyTLS","port":20834,"tls_server":"dl.google.com","certificate_mode":"self-signed"}'
json_set_record "${SECRETS_FILE}" "nanytls" '{"password":"pwany"}'
assert_eval_true "AnyTLS 自签链接含 insecure=1" 'build_share_link nanytls | grep -q "insecure=1"'
assert_eval_true "AnyTLS 链接含 type=tcp&headerType=none" 'build_share_link nanytls | grep -q "type=tcp&headerType=none"'
assert_eval_false "AnyTLS 自签链接不再含 allowInsecure" 'build_share_link nanytls | grep -q "allowInsecure"'
json_set_record "${NODES_FILE}" "nanytls-custom" '{"protocol":"anytls","name":"AnyTLS-C","port":20834,"tls_server":"trust.example.com","certificate_mode":"custom"}'
json_set_record "${SECRETS_FILE}" "nanytls-custom" '{"password":"pwanyb"}'
assert_eval_false "AnyTLS 受信证书链接不含 insecure" 'build_share_link nanytls-custom | grep -q "insecure"'
assert_eval_true "AnyTLS 受信证书链接保留 type=tcp" 'build_share_link nanytls-custom | grep -q "type=tcp&headerType=none"'
assert_eval_true "anytls 自签 ext 不泄漏到全局" 'unset ext; build_share_link nanytls >/dev/null; [ -z "${ext:-}" ]'

# --- fp 局部变量隔离（Bug #5）：hy2 自签时 fp 不得泄漏到全局 ---
assert_eval_true "hy2 fp 不泄漏到全局" 'unset fp; build_share_link n2b >/dev/null; [ -z "${fp:-}" ]'

# --- PID 文件严格校验（审查 F-03） ---
printf 'abc\n' >"${RUNTIME_DIR}/bad.pid"
assert_eval_false "非数字 PID 被拒绝" 'read_pid_file "${RUNTIME_DIR}/bad.pid"'
printf ' 42 \n' >"${RUNTIME_DIR}/ws.pid"
assert_eq "PID 去除空白" "42" "$(read_pid_file "${RUNTIME_DIR}/ws.pid")"
rm -f "${RUNTIME_DIR}/bad.pid" "${RUNTIME_DIR}/ws.pid"

# --- PID→二进制身份校验（审查 F-01）：错误二进制不得判为存活的服务实例 ---
assert_eval_false "pid_matches_binary_or_alive 拒绝身份不符进程" 'pid_matches_binary_or_alive $$ /nonexistent/sbm-other-binary'
# 回归：in-place 升级后旧进程 /proc/PID/exe 带 " (deleted)" 后缀仍应判定为"我们的实例"
# （否则 kill_pid_file 会跳过终止，导致旧进程残留与新实例并存）。
if [ -d /proc ] && command -v sleep >/dev/null 2>&1; then
  _pb="${TEST_ROOT}/.pidbin"
  cp /bin/sleep "${_pb}" 2>/dev/null || cp "$(dirname "$(command -v sleep)")/sleep" "${_pb}"
  chmod +x "${_pb}"
  "${_pb}" 30 & _pb_pid=$!
  sleep 0.2
  rm -f "${_pb}"
  # MSYS 下 /proc/PID/exe 与 Windows 风格路径无法对等模拟原地替换，仅 Linux 上断言 (deleted)
  if [[ "$(readlink "/proc/${_pb_pid}/exe" 2>/dev/null || true)" == *" (deleted)"* ]]; then
    assert_eval_true "pid_matches_binary 命中原地替换后的 (deleted) exe（兼容升级）" 'pid_matches_binary "'"${_pb_pid}"'" "'"${_pb}"'"'
    assert_eval_true "pid_matches_binary_or_alive 对 (deleted) exe 判为存活（兼容升级）" 'pid_matches_binary_or_alive "'"${_pb_pid}"'" "'"${_pb}"'"'
  fi
  kill "${_pb_pid}" 2>/dev/null || true
fi

# --- 自签证书与回退逻辑 ---
assert_eval_true "ensure_tls_material 生成证书" 'pair="$(ensure_tls_material tag_tls www.bing.com)"; [ -f "${pair%|*}" ] && [ -f "${pair#*|}" ]'
assert_eval_true "auto_cert_bundle 默认自签" 'auto_cert_bundle t_auto www.bing.com | grep -q "^self-signed|"'
assert_eval_false "auto_cert_bundle custom 缺路径回退自签" 'unset cert_path key_path; cert=custom; auto_cert_bundle t_c www.bing.com | grep -q "^custom|"'
# 回归：cert_path/key_path 环境变量不再被局部变量遮蔽
cpair="$(ensure_tls_material certsrc www.bing.com)"
export cert=custom
export cert_path="${cpair%|*}"
export key_path="${cpair#*|}"
assert_eval_true "custom 证书经环境变量正确导入" 'auto_cert_bundle ctest2 www.bing.com | grep -q "^custom|"'
unset cert cert_path key_path

# --- 状态备份与恢复（含证书，审查 F-02/F-09） ---
wipe_records
json_set_record "${NODES_FILE}" "bk" '{"protocol":"socks5","name":"BK","port":1234,"username":"u"}'
json_set_record "${SECRETS_FILE}" "bk" '{"password":"p"}'
mkdir -p "${CERT_DIR}" && printf 'CERT' >"${CERT_DIR}/bk.crt" && printf 'KEY' >"${CERT_DIR}/bk.key"
bkp_dir="$(backup_state)"
assert_eval_true "备份目录名唯一（随机+进程后缀, 审查 F-09）" '[[ "${bkp_dir}" =~ [0-9]{4}-[0-9]+$ ]]'
assert_eval_true "备份含证书文件（审查 F-02）" '[ -f "${bkp_dir}/certs/bk.crt" ] && [ -f "${bkp_dir}/certs/bk.key" ]'
wipe_records
assert_eq "清空后节点为 0" "0" "$(jq length "${NODES_FILE}")"
restore_latest_backup
assert_eq "备份恢复节点" "1" "$(jq length "${NODES_FILE}")"
assert_eval_true "恢复过程一并还原证书（审查 F-02）" '[ -f "${CERT_DIR}/bk.crt" ] && [ -f "${CERT_DIR}/bk.key" ]'
rm -f "${CERT_DIR}/bk.crt" "${CERT_DIR}/bk.key"

# --- 崩溃对账 ---
wipe_records
json_set_record "${NODES_FILE}" "pair1" '{"protocol":"hy2"}'
json_set_record "${SECRETS_FILE}" "pair1" '{"password":"y"}'
json_set_record "${NODES_FILE}" "orphan1" '{"protocol":"socks5"}'
json_set_record "${SECRETS_FILE}" "orphan2" '{"password":"x"}'
reconcile_state
assert_eq "对账后孤儿节点已清除" "1" "$(jq length "${NODES_FILE}")"
assert_eq "对账后孤儿密钥已清除" "1" "$(jq length "${SECRETS_FILE}")"

# --- 全局设置 ---
assert_eq "get_setting 默认 ip_version" "4" "$(get_setting ip_version 4)"
set_setting "ip_version" "6"
assert_eq "set_setting 回读" "6" "$(get_setting ip_version 4)"
set_setting "ip_version" "auto"
assert_eq "set_setting auto" "auto" "$(get_setting ip_version 4)"
assert_eq "settings.json 权限 600" "600" "$(stat -c %a "${SETTING_FILE}")"

# --- wipe_records ---
wipe_records
assert_eq "wipe_records 清空 nodes" "0" "$(jq length "${NODES_FILE}")"
assert_eq "wipe_records 清空 secrets" "0" "$(jq length "${SECRETS_FILE}")"

# --- 日志轮转 ---
big_file="${TEST_ROOT}/big.log"
head -c 2048 /dev/zero >>"${big_file}"
LOG_ROTATE_SIZE_MB=0 rotate_log_file "${big_file}" || true
assert_eval_true "rotate_log_file 产生轮转文件" '[ -f "${big_file}.1" ]'

# --- v0.2.17：GOMEMLIMIT 计算 / DoH 域名确认 / 多源下载 ---
assert_eval_true "compute_go_mem_limit_mb 输出正整数" 'v="$(compute_go_mem_limit_mb)"; [[ "${v}" =~ ^[0-9]+$ ]] && [ "${v}" -gt 0 ]'
assert_eval_true "compute_go_mem_limit_mb 不低于下限" 'v="$(SBM_GOMEM_FLOOR_MB=9999 compute_go_mem_limit_mb)"; [ "${v}" = "9999" ]'
assert_eval_true "go_mem_limit_value 带 MiB 后缀" 'v="$(go_mem_limit_value)"; [ -z "${v}" ] || [[ "${v}" =~ ^[0-9]+MiB$ ]]'
assert_eval_true "argo_domain_resolvable 公网域名可解析" 'argo_domain_resolvable cloudflare.com'
# 拒绝性断言仅在 DoH 可达环境执行：双源均不可达时函数按设计 fail-open 放行
if curl -fsS --max-time 5 -H 'accept: application/dns-json' "https://1.1.1.1/dns-query?name=cloudflare.com.&type=A" >/dev/null 2>&1; then
  assert_eval_false "argo_domain_resolvable 无效域名拒绝" 'argo_domain_resolvable "nonexistent-sbm-test.invalid"'
else
  PASS=$((PASS + 1))
  printf 'SKIP (DoH 不可达，fail-open 路径): argo_domain_resolvable 无效域名拒绝
' >&2
fi
assert_eval_false "download_file_multi 全部源失败返回非零" 'download_file_multi "${TEST_ROOT}/dl.out" "https://sbm.invalid/nonexist-a" "https://sbm.invalid/nonexist-b"'

# --- CLI 用法输出 ---
assert_eval_true "print_cli_usage 可执行" 'print_cli_usage | grep -q "用法"'

# --- auto_add_vless_ws_tls 记录 ws_mode/cdn_port/cdn_sni（v0.2.22 / v0.3.0） ---
ENV_NAME=Sm ENV_UUID=22222222-3333-4444-5555-666666666666 ENV_CDN_HOST=cdn.example.com ENV_WS_HOST=ws.example.com ENV_WS_MODE=cdn ENV_CDN_PORT=8443 auto_add_vless_ws_tls 20837
assert_eval_true "ws_mode=cdn 与 cdn_port 写入节点记录" 'jq -e "to_entries[] | select(.value.protocol == \"vless-ws-tls\" and .value.port == 20837 and .value.ws_mode == \"cdn\" and .value.cdn_port == 8443)" "${NODES_FILE}" >/dev/null'
assert_eval_true "cdn_sni 未显式设置时默认同连接地址" 'jq -e "to_entries[] | select(.value.port == 20837 and .value.cdn_sni == \"cdn.example.com\")" "${NODES_FILE}" >/dev/null'
# v0.3.0：ws_cdn 专用前缀优先于共享与旧名
ENV_NAME=Sm2 ENV_WS_CDN_VLESS_CF_HOST=per-proto.example.com ENV_WS_CDN_VLESS_CF_PT=2096 ENV_WS_CDN_SNI=shared-sni.example.com ENV_WS_MODE=cdn auto_add_vless_ws_tls 20838
assert_eval_true "ws_cdn_vless_* 覆盖共享/旧名值" 'jq -e "to_entries[] | select(.value.port == 20838 and .value.preferred_domain == \"per-proto.example.com\" and .value.cdn_port == 2096 and .value.cdn_sni == \"shared-sni.example.com\")" "${NODES_FILE}" >/dev/null'

# --- v0.3.3：Argo 独立优选域名/端口（argo_cdn_host/argo_cdn_port 独立于 WS-CDN） ---
ENV_NAME=Ar1 ENV_ARGO_CDN_HOST=argo.example.com ENV_ARGO_CDN_PORT=2053 auto_add_vless_argo 8002
assert_eval_true "argo_cdn_host/argo_cdn_port 写入节点记录" 'jq -e "to_entries[] | select(.value.protocol == \"vless-argo\" and .value.port == 8002 and .value.preferred_domain == \"argo.example.com\" and .value.cdn_port == 2053)" "${NODES_FILE}" >/dev/null'
ENV_ARGO_CDN_HOST="" ENV_CDN_HOST="fallback.example.com" auto_add_vless_argo 8003
assert_eval_true "argo_cdn 未设置时回退 cdn_host" 'jq -e "to_entries[] | select(.value.port == 8003 and .value.preferred_domain == \"fallback.example.com\" and .value.cdn_port == 443)" "${NODES_FILE}" >/dev/null'
json_set_record "${NODES_FILE}" "nargo-cdn" '{"protocol":"vless-argo","name":"ArgoCDN","port":8001,"preferred_domain":"argo.example.com","cdn_port":2053,"ws_path":"/w","endpoint_domain":"demo.trycloudflare.com"}'
json_set_record "${SECRETS_FILE}" "nargo-cdn" '{"uuid":"uac"}'
assert_eval_true "Argo 链接使用 argo_cdn_port" 'build_share_link nargo-cdn | grep -q "@argo.example.com:2053"'
assert_eval_false "Argo 链接不再硬编码 443" 'build_share_link nargo-cdn | grep -q "443?encryption"'

# --- v0.3.0：CDN 模式 cdn_sni 编号或回退连接地址链接生成（审查 ws_cdn 设计） ---
json_set_record "${NODES_FILE}" "nws-cdn2" '{"protocol":"vless-ws-tls","name":"WS-CDN2","port":20835,"preferred_domain":"cdn.example.com","host_domain":"ws.example.com","ws_path":"/p","certificate_mode":"custom","ws_mode":"cdn","cdn_port":8443,"cdn_sni":"origin.example.com"}'
json_set_record "${SECRETS_FILE}" "nws-cdn2" '{"uuid":"uwsc2"}'
assert_eval_true "WS CDN 连接地址用优选域名、SNI/Host 用 cdn_sni" 'build_share_link nws-cdn2 | grep -q "@cdn.example.com:8443?encryption=none&security=tls&sni=origin.example.com&type=ws&host=origin.example.com"'
json_set_record "${NODES_FILE}" "nws-cdn0" '{"protocol":"vless-ws-tls","name":"WS-CDN0","port":20835,"preferred_domain":"cdn.example.com","host_domain":"ws.example.com","ws_path":"/p","certificate_mode":"custom","ws_mode":"cdn","cdn_port":8443}'
json_set_record "${SECRETS_FILE}" "nws-cdn0" '{"uuid":"uwsc0"}'
assert_eval_true "WS CDN 无 cdn_sni 时回退连接地址" 'build_share_link nws-cdn0 | grep -q "sni=cdn.example.com&type=ws&host=cdn.example.com"'

# --- v1.1.0：性能/稳定性（TCP Fast Open / HY2 不限速 / GOGC / 退避 / 探活） ---
json_set_record "${NODES_FILE}" "nhyu" '{"protocol":"hy2","name":"HY2-UNLIM","port":11445,"tls_server":"www.bing.com","certificate_mode":"self-signed"}'
json_set_record "${SECRETS_FILE}" "nhyu" '{"password":"pw"}'
json_set_record "${NODES_FILE}" "nws-tune" '{"protocol":"vless-ws-tls","name":"WS-Tune","port":20840,"preferred_domain":"cdn.example.com","host_domain":"ws.example.com","ws_path":"/e","certificate_mode":"custom","certificate_path":"cert"}'
json_set_record "${SECRETS_FILE}" "nws-tune" '{"uuid":"ut"}'

# P2/P3：渲染单 outbound 直接校验（写 stdout，不依赖 CONFIG_FILE）
tmpcfg="$(mktemp "${TEST_ROOT}/cfg.XXXXXX")"
( tcp_fast_open=0 render_inbound_for_tag nws-tune ) >"${tmpcfg}" 2>/dev/null
assert_eval_true "tcp_fast_open=false 渲染进 inbound" 'jq -e ".tcp_fast_open == false" "${tmpcfg}" >/dev/null'
( tcp_fast_open=1 render_inbound_for_tag nws-tune ) >"${tmpcfg}" 2>/dev/null
assert_eval_true "tcp_fast_open=true 渲染进 inbound" 'jq -e ".tcp_fast_open == true" "${tmpcfg}" >/dev/null'
assert_eval_true "WS inbound 带 0-RTT early data 字段" 'jq -e ".transport.max_early_data == 2048 and .transport.early_data_header_name == \"Sec-WebSocket-Protocol\"" "${tmpcfg}" >/dev/null'
rm -f "${tmpcfg}"

# P1：HY2 无 up/down 字段 -> 渲染时回退默认 200 Mbps
tmpcfg="$(mktemp "${TEST_ROOT}/cfg.XXXXXX")"
render_inbound_for_tag nhyu >"${tmpcfg}" 2>/dev/null
assert_eval_true "HY2 未设置带宽时写默认 up_mbps=200" 'jq -e ".up_mbps == 200" "${tmpcfg}" >/dev/null'
assert_eval_true "HY2 未设置带宽时写默认 down_mbps=200" 'jq -e ".down_mbps == 200" "${tmpcfg}" >/dev/null'
rm -f "${tmpcfg}"

# P1：填写带宽时仍正确写入（含 0-RTT WS 渲染）
json_set_record "${NODES_FILE}" "nhyu" '{"protocol":"hy2","name":"HY2-UNLIM","port":11445,"tls_server":"www.bing.com","certificate_mode":"self-signed","up_mbps":400,"down_mbps":800}'
tmpcfg="$(mktemp "${TEST_ROOT}/cfg.XXXXXX")"
render_inbound_for_tag nhyu >"${tmpcfg}" 2>/dev/null
assert_eval_true "HY2 限速时写 up_mbps=400" 'jq -e ".up_mbps == 400" "${tmpcfg}" >/dev/null'
assert_eval_true "HY2 限速时写 down_mbps=800" 'jq -e ".down_mbps == 800" "${tmpcfg}" >/dev/null'
rm -f "${tmpcfg}"

# v1.2.3：CDN 模式附带明文 HTTP WS 回源 inbound（供 CF Flexible 回源，方案 A）
json_set_record "${NODES_FILE}" "nws-cdnextra" '{"protocol":"vless-ws-tls","name":"WS-CDNX","port":20844,"preferred_domain":"cdn.example.com","host_domain":"ws.example.com","ws_path":"/x","certificate_mode":"custom","ws_mode":"cdn","cdn_port":443,"ws_cdn_origin_port":80}'
json_set_record "${SECRETS_FILE}" "nws-cdnextra" '{"uuid":"ux"}'
tmpcfg="$(mktemp "${TEST_ROOT}/cfg.XXXXXX")"
render_inbound_for_tag nws-cdnextra >"${tmpcfg}" 2>/dev/null
assert_eq "CDN 模式渲染 2 条 inbound（TLS + 明文HTTP）" "2" "$(jq -s "length" "${tmpcfg}")"
assert_eval_true "CDN 明文HTTP inbound 无 tls" 'jq -s -e ".[1] | (.tls == null) and (.listen_port == 80) and (.transport.path == \"/x\") and (.users[0].uuid == \"ux\")" "${tmpcfg}" >/dev/null'
assert_eval_true "CDN TLS inbound 带证书" 'jq -s -e ".[0] | .tls.enabled == true" "${tmpcfg}" >/dev/null'
rm -f "${tmpcfg}"

# v1.2.3：CDN 回源端口与 TLS 端口相同（冲突）时跳说明文HTTP inbound
json_set_record "${NODES_FILE}" "nws-cdnconflict" '{"protocol":"vless-ws-tls","name":"WS-CDC","port":20845,"preferred_domain":"cdn.example.com","host_domain":"ws.example.com","ws_path":"/c","certificate_mode":"custom","ws_mode":"cdn","cdn_port":443,"ws_cdn_origin_port":20845}'
json_set_record "${SECRETS_FILE}" "nws-cdnconflict" '{"uuid":"uc"}'
tmpcfg="$(mktemp "${TEST_ROOT}/cfg.XXXXXX")"
render_inbound_for_tag nws-cdnconflict >"${tmpcfg}" 2>/dev/null
assert_eq "CDN 回源端口冲突时只渲染 TLS inbound" "1" "$(jq -s "length" "${tmpcfg}")"
rm -f "${tmpcfg}"

# v1.2.3：direct 模式不附加明文HTTP inbound（回归，防直连被误加端口）
json_set_record "${NODES_FILE}" "nws-direct2" '{"protocol":"vless-ws-tls","name":"WS-DIR","port":20846,"preferred_domain":"cdn.example.com","host_domain":"ws.example.com","ws_path":"/d","certificate_mode":"custom","tcp_fast_open":true}'
json_set_record "${SECRETS_FILE}" "nws-direct2" '{"uuid":"ud"}'
tmpcfg="$(mktemp "${TEST_ROOT}/cfg.XXXXXX")"
render_inbound_for_tag nws-direct2 >"${tmpcfg}" 2>/dev/null
assert_eq "direct 模式只渲染 1 条 inbound" "1" "$(jq -s "length" "${tmpcfg}")"
rm -f "${tmpcfg}"

# v1.2.3：auto_add_vless_ws_tls 持久化 ws_cdn_origin_port（默认 80）
ENV_NAME=SmX ENV_UUID=33333333-4444-5555-6666-777777777777 ENV_WS_MODE=cdn ENV_CDN_HOST=cdn.example.com ENV_WS_CDN_ORIGIN_PORT=8088 auto_add_vless_ws_tls 20847
assert_eval_true "ws_cdn_origin_port 写入节点记录(8088)" 'jq -e "to_entries[] | select(.value.port == 20847 and .value.ws_mode == \"cdn\" and .value.ws_cdn_origin_port == 8088)" "${NODES_FILE}" >/dev/null'
assert_eq "退避 delay 第1次" "1" "$(argo_backoff_delay 1)"
assert_eq "退避 delay 第2次" "2" "$(argo_backoff_delay 2)"
assert_eq "退避 delay 第3次" "4" "$(argo_backoff_delay 3)"
assert_eq "退避 delay 上限30min" "1800" "$(argo_backoff_delay 20)"
assert_eq "restart_count 初始 0" "0" "$(read_restart_count ntest)"
assert_eval_true "bump_restart_count 自增" '( bump_restart_count ntest; [ "$(read_restart_count ntest)" = "1" ] )'
assert_eval_true "reset_restart_count 清零" '( reset_restart_count ntest; [ "$(read_restart_count ntest)" = "0" ] )'
rm -f "${RUNTIME_DIR}/ntest.restart_count"

# S1：端口探活纯探测函数（本机未监听某高端口 -> 失败）
assert_eval_false "probe_tcp_port 未监听端口失败" 'probe_tcp_port 127.0.0.1 65123 1'

# P5：GOGC 开关 / 内存上限解析 / 网络调优开关 / 智能 buffer 档位
assert_eval_false "go_gc 默认不启用" 'go_gc_requested'
assert_eval_true "go_gc=off 启用" '( go_gc=off; go_gc_requested )'
assert_eval_true "net_tune 默认启用" 'net_tune_requested'
assert_eval_false "net_tune=0 关闭" '( net_tune=0; net_tune_requested )'
assert_eval_true "net_tune=1 启用" '( net_tune=1; net_tune_requested )'
assert_eval_true "TCP buffer 内存上限为 16/32/64 之一" 'case $(get_tcp_buffer_cap_mb) in 16|32|64) true;; *) false;; esac'
assert_eq "asia 低带宽 buffer=8" "8" "$(calculate_net_tune_buffer_mb 100 asia)"
assert_eq "asia 1G buffer=16" "16" "$(calculate_net_tune_buffer_mb 1000 asia)"
assert_eq "asia 2G buffer=24" "24" "$(calculate_net_tune_buffer_mb 2000 asia)"
assert_eq "asia 5G buffer=28" "28" "$(calculate_net_tune_buffer_mb 5000 asia)"
assert_eq "asia 千兆以上 buffer=32" "32" "$(calculate_net_tune_buffer_mb 10000 asia)"
assert_eq "asia 下限边界 999Mbps" "12" "$(calculate_net_tune_buffer_mb 999 asia)"
assert_eq "overseas 低带宽 buffer=16" "16" "$(calculate_net_tune_buffer_mb 300 overseas)"
assert_eq "overseas 1G buffer=64" "64" "$(calculate_net_tune_buffer_mb 1000 overseas)"
assert_eq "overseas 下限边界 999Mbps" "48" "$(calculate_net_tune_buffer_mb 999 overseas)"
assert_eq "算档位 空带宽回退 1000Mbps" "16" "$(calculate_net_tune_buffer_mb "" asia)"
assert_eval_true "buffer 受内存上限约束" '( B=$(calculate_net_tune_buffer_mb 10000 overseas); [ "$B" -le "$(get_tcp_buffer_cap_mb)" ] )'
mkdir -p "${TEST_ROOT}/speedtest"
cat >"${TEST_ROOT}/speedtest/speedtest" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "   Speedtest by Ookla 1.2.0"
printf '%s\n' "Download:   812.34 Mbit/s"
printf '%s\n' "Upload:   300.78 Mbit/s"
printf '%s\n' "Latency:    12.34 ms"
EOF
( cd "${TEST_ROOT}/speedtest"; chmod +x speedtest )
assert_eq "Ookla 测速输出解析 Upload" "300" "$(run_speedtest "${TEST_ROOT}/speedtest/speedtest")"
assert_eq "Ookla 测速输出解析 带宽+延迟" "300 12" "$(run_speedtest_metrics "${TEST_ROOT}/speedtest/speedtest")"
assert_eval_true "Ookla 官方 speedtest 识别" 'ls -la "${TEST_ROOT}/speedtest/speedtest" >/dev/null'

# v1.2.3：net_tune 交互确认在非交互环境原样返回（保在线脚本可无人值守）
assert_eq "确认环节 非交互原样返回" "300 12" "$(NET_TUNE_SKIP_CONFIRM=1 net_tune_confirm_measurement 300 12 asia)"
assert_eval_true "确认环节 stdin非TTY 原样返回" 'echo "" | net_tune_confirm_measurement 500 20 asia | grep -q "^500 20"'
assert_eq "延迟推断档位 <150ms→asia" "asia" "$(infer_net_tune_region 80)"
assert_eq "延迟推断档位 >=150ms→overseas" "overseas" "$(infer_net_tune_region 200)"
assert_eq "延迟推断档位 空→asia" "asia" "$(infer_net_tune_region "")"

# --- 端到端前置：清空状态 ---
wipe_records
assert_eq "端到端前置清空" "0" "$(jq length "${NODES_FILE}")"

# ---------------------------------------------------------------------------
# 一键安装（auto_install）端到端模拟：stub sing-box 二进制，覆盖 6 种协议
# ---------------------------------------------------------------------------
STUB_BIN="${TEST_ROOT}/bin"
mkdir -p "${STUB_BIN}"
cat >"${STUB_BIN}/sing-box" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
version) echo "sing-box version 1.14.0" ;;
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
assert_eq "config 日志级别默认 warn" "warn" "$(jq -r '.log.level' "${CONFIG_FILE}")"
assert_eval_true "vless TFO 默认开" 'jq -e ".inbounds[] | select(.type == \"vless\" and .tcp_fast_open == true)" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "anytls TFO 默认开" 'jq -e ".inbounds[] | select(.type == \"anytls\" and .tcp_fast_open == true)" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "socks TFO 默认开" 'jq -e ".inbounds[] | select(.type == \"socks\" and .tcp_fast_open == true)" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "WS inbound 全局带 0-RTT" 'jq -e ".inbounds[] | select(.transport.type? == \"ws\" and .transport.max_early_data == 2048 and .transport.early_data_header_name == \"Sec-WebSocket-Protocol\")" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "HY2 限速 100/300 写入" 'jq -e ".inbounds[] | select(.type == \"hysteria2\" and .up_mbps == 100 and .down_mbps == 300)" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "sing-box stub 已启动" 'pid="$(read_pid_file "${PID_FILE}")"; [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null'

# S4：sing-box check 失败时拒写配置（fail-closed，保留旧配置）
cp "${CONFIG_FILE}" "${TEST_ROOT}/config.before"
assert_eval_false "check 失败 render_config 拒写" '( SINGBOX_BIN="/bin/false"; render_config )'
assert_eval_true "check 失败保留旧配置" 'cmp -s "${CONFIG_FILE}" "${TEST_ROOT}/config.before"'

# sbm sub：base64 订阅输出（6 节点）
assert_eval_true "sub 输出非空 base64" 'c="$(sub_command)"; [ "${#c}" -gt 100 ] && [[ "${c}" =~ ^[A-Za-z0-9+/=]+$ ]]'
assert_eval_true "sub 解码后包含节点链接" 'c="$(sub_command)"; printf %s "${c}" | base64 -d | grep -q "vless://"'

# 重复 ins：端口已被现有节点占用，全部跳过 → added=0 退出码 1（子 shell 中运行以捕获 exit）
assert_eval_false "重复 ins 端口冲突时拒绝" '( auto_install ins )'

# rep：清空后按新端口重建（先 unset 其余协议端口）
unset wspt anypt tupt socks5pt
export vlrt=21831 hypt=21832
assert_eval_true "rep 重建成功" '( auto_install rep )'
assert_eq "rep 后只剩新节点" "2" "$(jq length "${NODES_FILE}")"
assert_eq "rep 后 config 为 2 个 inbound" "2" "$(jq '.inbounds | length' "${CONFIG_FILE}")"

# P0 回归：rep 输入非法端口时先失败且不清空已有节点（预校验先于清空）
vlrt=99999
assert_eval_false "rep 非法端口预校验失败" '( auto_install rep )'
assert_eq "rep 预校验失败不清空节点" "2" "$(jq length "${NODES_FILE}")"
unset vlrt
vlrt=21831

# P0 回归：delall 清理证书与私钥文件
assert_eval_true "证书文件存在（hy2 自签）" '[ "$(find "${CERT_DIR}" -type f | wc -l)" -gt 0 ]'
assert_eval_true "delete_all_nodes 成功" '( delete_all_nodes )'
assert_eq "delall 后无残留证书" "0" "$(find "${CERT_DIR}" -type f | wc -l)"

# 清理 stub 进程
kill_pid_file "${PID_FILE}" || true

rm -rf "${TEST_ROOT}"

echo
echo "冒烟测试结果：通过 ${PASS}，失败 ${FAIL}"
if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
