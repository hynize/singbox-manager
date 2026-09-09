# Singbox Manager

**在线一键命令生成器：<https://sbm.1733.dpdns.org>** —— 填协议端口即可生成下面的环境变量一键安装命令。

面向常用 `sing-box` 场景的管理脚本：安装核心、添加节点、生成分享链接、自动保活一体化，支持 VLESS-Reality / VLESS-WS-TLS / AnyTLS / VLESS-Argo / TUIC v5 / Hysteria2 / SOCKS5。

## 快速安装

```bash
bash <(curl -fsSL https://github.com/hynize/singbox-manager/releases/latest/download/install.sh)
sbm          # 打开交互菜单
```

## 环境变量一键安装

端口变量启用对应协议，其余可选；`rep` 清空重建（适合首次/重置），`ins` 保留已有节点追加：

```bash
vlrt=2083 hypt=2082 name='HK' bash <(curl -fsSL https://github.com/hynize/singbox-manager/releases/latest/download/install.sh)
vlrt=2083 hypt=2082 name='HK' sbm rep      # 已安装时
```

| 变量 | 说明 | 默认 |
|---|---|---|
| `vlrt` `wspt` `tupt` `anypt` `hypt` `socks5pt` | 各协议端口，填了即启用 | 不启用 |
| `argo=vlpt` `argo_pt` | 启用 VLESS-Argo；本地端口 | 8001 |
| `agn` `agk` | Argo 固定隧道域名 + Token（临时隧道留空） | 临时隧道 |
| `cdn_host` | CDN 中转连接地址（优选 IP/域名），Argo 与 WS-TLS 共用 | `saas.sin.fan` |
| `ws_mode` | WS-TLS 连接方式：`cdn`（经 `cdn_host` 中转）或 `direct` 直连服务器 IP（脚本后端保留，命令行可设） | `direct` |
| `cdn_port` | WS-TLS `cdn` 模式使用的 CDN 转发端口（如 443/8443/2053/2096） | `443` |
| `ws_cdn_cf_host` | ws_cdn 共享 CDN 连接地址（专用前缀，覆盖 `cdn_host`） | `cdn_host` |
| `ws_cdn_cf_pt` | ws_cdn 共享 CDN 转发端口（专用前缀，覆盖 `cdn_port`） | `cdn_port` |
| `ws_cdn_sni` | **必填**：ws_cdn 回源域名 = 客户端 SNI/Host（默认同连接地址，可单独设真实回源域名） | 连接地址 |
| `ws_cdn_vless_cf_host/ws_cdn_vless_cf_pt/ws_cdn_vless_sni` | VLESS 专属覆盖（优先于 `ws_cdn_*` 共享值） | 共享值 |
| `confirm_default_cdn=1` | 确知并接受默认优选域名时消除对应警告 | 未设置 |
| `uuid` | VLESS/TUIC 共用 UUID | 自动生成 |
| `passwd` | AnyTLS/HY2/TUIC 密码 | 自动生成 |
| `name` | 节点名前缀（生成 `HK-Reality` 等） | 内置默认名 |
| `cert` `cert_path` `key_path` | `custom` 时导入自有证书 | 自签 |
| `vl_sni` `ws_host` `tu_sni` `any_sni` `hy_sni` | 各协议 SNI（ws_host 仅供命令行 `ws_mode=direct` 直连用；界面 WS 已仅 CDN，SNI/Host 用 `ws_cdn_sni`） | `www.apple.com` |
| `ws_path` | WS 路径 | 随机 |
| `up_mbps` `down_mbps` | HY2 带宽 | 200 |
| `socks5_username` `socks5_password` | SOCKS5 账号 | user / 随机 |

## 命令行

```text
sbm           交互菜单（安装/添加/查看/删除/重启/状态/更新/卸载/全局设置）
sbm rep|ins   环境变量一键安装（自动快照备份；rep 端口非法时直接拒绝，不动现有数据）
sbm list      查看节点与分享链接
sbm sub [文件] 输出 base64 订阅（不带参数打印到 stdout，带文件参数写入文件）
sbm delall    删除全部节点（含证书，自动快照）
sbm restore   从最近一次快照恢复节点
sbm un        卸载
```

分享链接默认使用 IPv4；菜单「9. 全局设置」可切换 `v4 / v6 / auto`（仅双栈机器需要调整）。

## 项目结构

```text
sb.sh / install.sh / lib/common.sh / metadata/upstream.env
scripts/watchdog.sh          保活（systemd timer 或 cron，每分钟）
scripts/build-release-bundle.sh
interface/                   网页命令生成器（Pages / Workers 部署）
tests/smoke.sh               冒烟测试
```

## 说明

- 稳健性：`rep`/`ins`/`delall` 前自动快照到 `backups/`（保留 10 份，目录含唯一后缀，且一并备份自签证书/私钥），`sbm restore` 一键回滚；`rep` 在"清空已有节点后"至"提交前"任一环节失败都会自动恢复到安装前状态；watchdog 每轮自动对账清理孤儿记录；Argo 临时域名经公共 DNS（DoH，A/AAAA 任一可解析即通过）发布确认后才写入节点；Argo Token 经环境变量传递，不出现在进程命令行
- 进程识别：service/watchdog 的存活判断与清理全部做 PID→预期二进制的身份校验（`/proc` 可用时），PID 被复用不会导致漏重启或误杀；临时 Argo 隧道日志每次启动截断，避免旧进程残留域名被误解析
- 交付韧性：sing-box 固定版本 + SHA256（官方 → 本仓库镜像多源回退）；cloudflared 强校验模型——拿不到官方 SHA256 时默认 **fail-closed 拒绝安装**，绝不静默以"版本自报"代替完整性校验；仅当显式设置 `CLOUDFLARED_ALLOW_RUNTIME_VERIFY=1` 才允许降级（弱网机器的明确选择，不推荐用于生产）
- 低内存：sing-box/cloudflared 按物理内存与 cgroup 上限自动设置 `GOMEMLIMIT` 软上限（防 OOM）；cloudflared 默认 `http2` 模式压内存尖峰；低于 200MB 内存自动提示资源约束
- 保活：systemd 环境用 service + timer；OpenRC/无 systemd 用 cron + pidfile，cloudflared 异常退出约 1 分钟内自动拉起
- 安全：`set -eEuo pipefail`、`umask 077`、secrets/证书/pid 全部 600；分享链接 authority 对 IPv6 正确加方括号（不再先做查询参数编码）；`build_share_link` 局部变量隔离（`fp` 不泄漏到全局）
- CI：shellcheck / bash -n / shfmt / 冒烟测试 / 可复现 bundle 构建 / 版本与 `worker.js` 一致性门禁
- 上游版本见 `metadata/upstream.env`

## 发布流程

1. 更新代码与 `VERSION`
2. `bash scripts/build-release-bundle.sh`，将新校验值同步到 `install.sh`
3. 上传 bundle、checksums.txt、install.sh 到 GitHub Release

### 可选：二进制镜像源

在仓库创建 `upgrade-mirror` Release 并上传 `metadata/upstream.env` 中列出的 sing-box 压缩包与 cloudflared 二进制（文件名保持一致），弱网机器在官方源不可达时自动回退到该镜像；所有镜像文件仍执行相同 SHA256 校验。不上传镜像不影响正常功能。

## 注意事项

- `sbm rep` 会清空全部节点；`TUIC` 自签模式链接默认带跳过校验参数
- Argo 临时隧道域名会变化，用 `sbm list` 获取最新地址
