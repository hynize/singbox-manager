# Singbox Manager

**在线一键命令生成器：<https://sbm.1733.dpdns.org>** —— 填协议端口即可生成下面的环境变量一键安装命令。

面向常用 `sing-box` 场景的管理脚本：安装核心、添加节点、生成分享链接、自动保活一体化，支持 VLESS-Reality / VLESS-WS-TLS / AnyTLS / VLESS-Argo / TUIC v5 / Hysteria2 / SOCKS5。

## 快速安装

```bash
bash <(curl -fsSL https://github.com/hynize/singbox-manager/releases/download/v0.2.10/install.sh)
sbm          # 打开交互菜单
```

## 环境变量一键安装

端口变量启用对应协议，其余可选；`rep` 清空重建（适合首次/重置），`ins` 保留已有节点追加：

```bash
vlrt=2083 hypt=2082 name='HK' bash <(curl -fsSL https://github.com/hynize/singbox-manager/releases/download/v0.2.10/install.sh)
vlrt=2083 hypt=2082 name='HK' sbm rep      # 已安装时
```

| 变量 | 说明 | 默认 |
|---|---|---|
| `vlrt` `wspt` `tupt` `anypt` `hypt` `socks5pt` | 各协议端口，填了即启用 | 不启用 |
| `argo=vlpt` `argo_pt` | 启用 VLESS-Argo；本地端口 | 8001 |
| `agn` `agk` | Argo 固定隧道域名 + Token（临时隧道留空） | 临时隧道 |
| `uuid` | VLESS/TUIC 共用 UUID | 自动生成 |
| `passwd` | AnyTLS/HY2/TUIC 密码 | 自动生成 |
| `name` | 节点名前缀（生成 `HK-Reality` 等） | 内置默认名 |
| `cert` `cert_path` `key_path` | `custom` 时导入自有证书 | 自签 |
| `vl_sni` `ws_host` `ws_path` `cdn_host` | Reality 域名 / WS SNI / WS 路径 / 优选域名 | 内置默认 |
| `tu_sni` `any_sni` `hy_sni` | 对应协议 SNI | `www.bing.com` |
| `up_mbps` `down_mbps` | HY2 带宽 | 200 |
| `socks5_username` `socks5_password` | SOCKS5 账号 | user / 随机 |

## 命令行

```text
sbm           交互菜单（安装/添加/查看/删除/重启/状态/更新/卸载/全局设置）
sbm rep|ins   环境变量一键安装
sbm list      查看节点与分享链接
sbm delall    删除全部节点
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

- 保活：systemd 环境用 service + timer；OpenRC/无 systemd 用 cron + pidfile，cloudflared 异常退出约 1 分钟内自动拉起
- 安全：`set -eEuo pipefail`、`umask 077`、secrets/证书/pid 全部 600；sing-box 固定版本 + SHA256，cloudflared 跟随官方最新版并校验 digest
- CI：shellcheck / bash -n / shfmt / 冒烟测试 / 可复现 bundle 构建
- 上游版本见 `metadata/upstream.env`

## 发布流程

1. 更新代码与 `VERSION`
2. `bash scripts/build-release-bundle.sh`，将新校验值同步到 `install.sh`
3. 上传 bundle、checksums.txt、install.sh 到 GitHub Release

## 注意事项

- `sbm rep` 会清空全部节点；`TUIC` 自签模式链接默认带跳过校验参数
- Argo 临时隧道域名会变化，用 `sbm list` 获取最新地址
