# Singbox Manager

**在线一键命令生成器：<https://sbm.1733.dpdns.org>** —— 填协议端口即可生成下面的环境变量一键安装命令。

一个面向常用 `sing-box` 场景的交互式管理项目，目标是把“安装核心、添加节点、生成链接、自动保活、日常维护”整合为一个可发布、可校验、可运维的 Bash 项目。

## 一键地址

发布版安装脚本：

```text
https://github.com/hynize/singbox-manager/releases/download/v0.2.9/install.sh
```

快速安装：

```bash
bash <(curl -fsSL https://github.com/hynize/singbox-manager/releases/download/v0.2.9/install.sh)
```

更安全的两步安装：

```bash
curl -fsSLO https://github.com/hynize/singbox-manager/releases/download/v0.2.9/install.sh
bash install.sh
```

安装完成后运行：

```bash
sbm
```

## 环境变量一键安装（无需交互）

sbm 支持完全非交互的一键安装：端口类环境变量启用对应协议，其余变量提供可选配置。

```bash
# 首次部署（未安装）：自动下载安装核心并按环境变量建节点
vlrt=2083 hypt=2082 name='HK' bash <(curl -fsSL https://github.com/hynize/singbox-manager/releases/download/v0.2.9/install.sh)

# 已安装：直接调用 sbm
vlrt=2083 hypt=2082 name='HK' sbm rep
```

- `rep`（覆盖式）：先清空已有节点，再按环境变量重建，适合首次部署或重置。
- `ins`（追加式）：保留已有节点，追加新节点；端口与现有节点冲突时跳过该协议。
- 未检测到任何节点端口变量时拒绝执行，防止误操作。

### 环境变量总表

| 变量 | 说明 | 默认 |
|---|---|---|
| `vlrt` | 启用 VLESS-Reality，值为端口 | 不启用 |
| `wspt` | 启用 VLESS-WS-TLS，值为端口 | 不启用 |
| `tupt` | 启用 TUIC v5，值为端口 | 不启用 |
| `anypt` | 启用 AnyTLS，值为端口 | 不启用 |
| `hypt` | 启用 Hysteria2，值为端口 | 不启用 |
| `socks5pt` | 启用 SOCKS5，值为端口 | 不启用 |
| `argo` | 设为 `vlpt` 启用 VLESS-Argo | 不启用 |
| `argo_pt` | Argo 本地监听端口 | `8001` |
| `agn` | Argo 固定隧道回源域名 | 临时隧道 |
| `agk` | Argo 固定隧道 Token（与 `agn` 需同时提供） | 空 |
| `uuid` | VLESS/TUIC 共用 UUID | 自动生成 |
| `passwd` | AnyTLS/HY2/TUIC 共用密码 | 自动生成 |
| `name` | 节点名称前缀（生成 `HK-Reality` 等） | 内置默认名 |
| `cert` | `self` 自签 / `custom` 导入证书 | `self` |
| `cert_path` / `key_path` | 自定义证书与私钥路径（`cert=custom` 时必填） | 空 |
| `vl_sni` | Reality 伪装域名 | `www.apple.com` |
| `ws_host` | WS Host/SNI 域名 | `www.bing.com` |
| `ws_path` | WebSocket 路径（WS/Argo 共用） | 随机 |
| `cdn_host` | CF 优选域名 | 本机 IP / `saas.sin.fan` |
| `tu_sni` / `any_sni` / `hy_sni` | TUIC / AnyTLS / HY2 的 SNI | `www.bing.com` |
| `up_mbps` / `down_mbps` | Hysteria2 上下行带宽 | `200` |
| `socks5_username` / `socks5_password` | SOCKS5 账号 | `user` / 随机 |

不想手写命令？仓库自带网页命令生成器（见下节），填表即可生成上述命令。

## 网页一键命令生成器（interface）

线上地址：<https://sbm.1733.dpdns.org>

`interface/` 目录提供一个纯静态单文件网页（单页设计：协议端口 + 全局配置 + Argo 隧道 + SOCKS5 账号 + 快捷指令速查一页搞定）：填协议端口与配置，实时生成一键 SSH 命令，支持深浅色主题、随机端口/UUID/密码生成。其他 Linux 命令可查询 [pkg.tbbbk.com](https://pkg.tbbbk.com/)（180+ 应用一键安装命令）。

两种部署任选：

- **GitHub Pages**：推送后 Actions 自动部署 `interface/`（`.github/workflows/deploy-pages.yml`）。
- **Cloudflare Workers**：`cd interface && wrangler deploy`，或在 Actions 手动运行 `Deploy to Cloudflare Workers`（需配置 `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID`）。

修改界面：编辑 `interface/index.html` 后运行 `python interface/build.py` 重新生成 `worker.js`。

## 功能范围

- 支持 `VLESS + Reality`
- 支持 `VLESS + WS + TLS`
- 支持 `AnyTLS`
- 支持 `VLESS + Argo`
- 支持 `TUIC v5`
- 支持 `Hysteria2`
- 支持 `SOCKS5`
- 所有协议端口可自定义
- 所有节点名称可自定义
- 支持环境变量一键安装（`sbm rep` / `sbm ins`），并配套网页命令生成器
- `VLESS + Argo`、`VLESS + WS + TLS` 支持自定义优选域名，默认 `saas.sin.fan`
- `VLESS + Reality` 默认伪装域名 `www.apple.com`
- `TUIC v5` 在自签证书模式下默认附带跳过证书验证参数
- UUID 留空时自动生成
- 支持自动保活 `sing-box + cloudflared`
- 支持日志轮转
- 支持 `OpenRC`
- 支持发布版自更新
- `VLESS + Argo` 自动识别纯 IPv6 机器，强制走 IPv6 边缘节点

## 交互目录设计

主菜单：

```text
1. 安装/更新核心组件
2. 添加节点
3. 查看节点
4. 删除节点
5. 重启服务
6. 查看状态
7. 更新项目文件
8. 卸载
0. 退出
```

添加节点子菜单：

```text
1. VLESS + Reality
2. VLESS + WS + TLS
3. AnyTLS
4. VLESS + Argo
5. TUIC v5
6. Hysteria2
7. SOCKS5
0. 返回
```

## 命令行子命令

```text
sbm           打开交互式主菜单
sbm rep       覆盖式一键安装（按环境变量重建节点）
sbm ins       追加式一键安装（保留已有节点）
sbm list      查看节点与分享链接
sbm delall    删除全部节点并重启服务
sbm un        卸载本项目
sbm help      查看命令用法
```

## 项目结构

仓库目录：

```text
.
├─ .github/workflows/
│  ├─ ci.yml
│  ├─ deploy-pages.yml
│  └─ deploy-workers.yml
├─ install.sh
├─ sb.sh
├─ VERSION
├─ lib/common.sh
├─ metadata/upstream.env
├─ tests/smoke.sh
├─ interface/            # 网页一键命令生成器
│  ├─ index.html
│  ├─ worker.js
│  ├─ wrangler.toml
│  └─ build.py
└─ scripts/
   ├─ build-release-bundle.sh
   └─ watchdog.sh
```

服务器落地目录：

```text
/usr/local/bin/
└─ sbm

/usr/local/lib/singbox-manager/
├─ common.sh
└─ upstream.env

/usr/local/etc/singbox-manager/
├─ config.json
├─ nodes.json
├─ secrets.json
├─ certs/
├─ logs/
├─ runtime/
└─ watchdog.sh
```

## 实现方式

### 安装链路

- `install.sh` 不再直接拉取 `main` 分支脚本。
- 安装器固定到发布版本 `v0.2.9`。
- 安装内容来自 release bundle：`singbox-manager-v0.2.9.tar.gz`
- 安装器会对 bundle 做 SHA256 校验后再解包。
- 传入 `rep`/`ins` 参数或携带节点环境变量时，安装完成后直接进入一键安装模式。

### 公共逻辑层

- `lib/common.sh` 统一提供：
  - 严格模式 `set -eEuo pipefail`
  - `umask 077`
  - 全局锁
  - `BusyBox flock` 兼容锁轮询
  - Alpine `musl/glibc` 兼容补丁
  - 日志轮转
  - 原子 JSON 写入
  - 权限收敛
  - 校验和验证
  - Argo 临时域名轮询
  - 分享链接构建

### 数据分层

- `nodes.json` 只保存展示和配置所需元数据。
- `secrets.json` 单独保存 UUID、密码、Reality 私钥、Argo token 等敏感内容。
- 不再把分享链接持久化到磁盘；查看节点时实时生成。

### 配置生成

- 所有协议先写入 `nodes.json + secrets.json`。
- `render_config` 根据节点元数据动态生成完整 `config.json`。
- 每次增删节点后都会重新校验并重载服务。

### 并发控制

- 所有写入 `nodes.json`、`secrets.json`、`config.json` 的动作都使用全局锁。
- watchdog 和交互菜单不会再同时改同一批状态文件。

## 各协议说明

### VLESS + Reality

- 默认域名：`www.apple.com`
- 自动生成：
  - UUID
  - Reality 密钥对
  - `short_id`
- 生成标准 `reality` 分享链接

### VLESS + WS + TLS

- 默认优选域名：`saas.sin.fan`
- 支持自定义：
  - 端口
  - 节点名称
  - UUID
  - 优选域名
  - `Host/SNI`
  - `WS Path`
- 证书模式：
  - `self-signed`
  - `custom`

### AnyTLS

- 支持自定义密码和 SNI
- 支持自签证书或导入现有证书

### VLESS + Argo

- 支持临时隧道
- 支持 Token 固定隧道
- 临时隧道采用“带超时的轮询”探测 `trycloudflare` 域名
- watchdog 会自动拉起异常退出的 `cloudflared`

### TUIC v5

- 自动生成 UUID
- 密码留空默认复用 UUID
- 自签证书模式下默认生成 `allow_insecure=1`
- 支持自签证书和自定义证书

### Hysteria2

- 自动生成密码
- 支持自定义上下行带宽
- 自签证书模式下分享链接会附带 `insecure=1`
- 自定义证书模式下默认不附带不安全参数

### SOCKS5

- 支持自定义用户名/密码
- 适合作为本地代理入口

## 快速模式与生产模式

### 快速模式

- 选择 `self-signed` 证书
- 适合自用、内网测试、快速拉起
- `WS + TLS` / `AnyTLS` / `Hysteria2` 会按需要生成不安全客户端参数

### 生产模式

- 选择 `custom` 证书
- 使用正式证书和私钥
- 分享链接默认不再附加多余的跳过校验参数

## 自动保活

### systemd 环境

- 创建 `singbox-manager.service`
- 创建 `singbox-manager-watchdog.service`
- 创建 `singbox-manager-watchdog.timer`
- 主服务增加 `ExecStartPre` 配置校验
- 增加一组基础 sandbox 选项

### 非 systemd 环境

- 使用 `cron` 每分钟执行 `watchdog.sh`
- 使用显式 pidfile 管理 `sing-box`
- 不再使用 `pkill -f` 这类模糊匹配

## 安全设计

- 默认 `set -eEuo pipefail`
- 默认 `umask 077`
- `nodes.json`、`secrets.json`、`config.json`、证书私钥、运行时 pid 全部按最小权限落盘
- 上游 `sing-box` 采用固定版本和固定 SHA256
- `cloudflared` 跟随官方最新版（通过 GitHub API 获取最新版本与官方 digest 校验），API 不可用时回退到内置固定版本
- release bundle 可复现，CI 会执行：
  - `shellcheck`
  - `bash -n`
  - `shfmt -d`
  - 冒烟测试（`tests/smoke.sh`）
  - release bundle 构建

## 当前版本

- `sing-box`: `v1.13.16`（固定）
- `cloudflared`: 跟随官方最新版（内置回退版本 `2026.7.3`）

详细版本与校验和位于 `metadata/upstream.env`。

## 发布流程

1. 更新代码与 `VERSION`
2. 运行 `bash scripts/build-release-bundle.sh`
3. 将 `checksums.txt` 中 bundle 的 SHA256 更新到 `install.sh` 的 `PACKAGE_SHA256`
4. 上传 `singbox-manager-<version>.tar.gz` 和 `checksums.txt` 到 GitHub Release
5. 发布同版本的 `install.sh`

## 注意事项

- `TUIC v5` 的跳过证书校验是按需求保留的默认行为。
- `Argo` 临时隧道的域名会变化，重新进入 `sbm list` 查看即可拿到最新地址。
- 默认优选域名 `saas.sin.fan` 仅作为默认值，实际是否适合请自行测试。
- `sbm rep` 会清空全部节点，请确认后再执行。
- `cloudflared` 异常退出后，watchdog 会在约 1 分钟内自动拉起（已实测：杀掉进程后自动恢复，固定隧道域名随之恢复访问）。
- 一键安装已在 Debian 13 实测通过：`rep` / `ins` / `list` / `delall`、端口冲突跳过、Argo 固定隧道（Token 模式）端到端连通、watchdog 自动恢复。
