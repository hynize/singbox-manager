# Singbox Manager

一个面向常用 `sing-box` 场景的交互式管理项目，目标是把“安装核心、添加节点、生成链接、自动保活、日常维护”整合为一个可发布、可校验、可运维的 Bash 项目。

## 一键地址

发布版安装脚本：

```text
https://github.com/hynize/singbox-manager/releases/download/v0.2.2/install.sh
```

快速安装：

```bash
bash <(curl -fsSL https://github.com/hynize/singbox-manager/releases/download/v0.2.2/install.sh)
```

更安全的两步安装：

```bash
curl -fsSLO https://github.com/hynize/singbox-manager/releases/download/v0.2.2/install.sh
bash install.sh
```

安装完成后运行：

```bash
sbm
```

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
- `VLESS + Argo`、`VLESS + WS + TLS` 支持自定义优选域名，默认 `saas.sin.fan`
- `VLESS + Reality` 默认伪装域名 `www.apple.com`
- `TUIC v5` 分享链接默认附带跳过证书验证参数
- UUID 留空时自动生成
- 支持自动保活 `sing-box + cloudflared`
- 支持发布版自更新

## 交互目录设计

主菜单：

```text
1. Install/Update core
2. Add node
3. View nodes
4. Delete node
5. Restart services
6. Status
7. Update project files
8. Uninstall
0. Exit
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
0. Back
```

## 项目结构

仓库目录：

```text
.
├─ .github/workflows/ci.yml
├─ install.sh
├─ sb.sh
├─ VERSION
├─ lib/common.sh
├─ metadata/upstream.env
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
- 安装器固定到发布版本 `v0.2.2`。
- 安装内容来自 release bundle：`singbox-manager-v0.2.2.tar.gz`
- 安装器会对 bundle 做 SHA256 校验后再解包。

### 公共逻辑层

- `lib/common.sh` 统一提供：
  - 严格模式 `set -eEuo pipefail`
  - `umask 077`
  - 全局锁
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
- 默认生成 `allow_insecure=1`
- 支持自签证书和自定义证书

### Hysteria2

- 自动生成密码
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
- 上游 `sing-box` 与 `cloudflared` 采用固定版本和固定 SHA256
- release bundle 可复现，CI 会执行：
  - `shellcheck`
  - `bash -n`
  - `shfmt -d`
  - release bundle 构建

## 当前固定版本

- `sing-box`: `v1.13.8`
- `cloudflared`: `2026.3.0`

详细版本与校验和位于 `metadata/upstream.env`。

## 发布流程

1. 更新代码与 `VERSION`
2. 运行 `bash scripts/build-release-bundle.sh`
3. 上传 `singbox-manager-<version>.tar.gz` 和 `checksums.txt` 到 GitHub Release
4. 发布同版本的 `install.sh`

## 注意事项

- `TUIC v5` 的跳过证书校验是按需求保留的默认行为。
- `Argo` 临时隧道的域名会变化，重新进入 `sbm` 查看即可拿到最新地址。
- 默认优选域名 `saas.sin.fan` 仅作为默认值，实际是否适合请自行测试。
