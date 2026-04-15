# Singbox Manager

一个面向常用协议场景的 `sing-box` 一键管理项目，目标是把“安装核心、添加节点、生成链接、自动保活、日常维护”整合成一个可直接落地的交互式脚本。

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hynize/singbox-manager/main/install.sh)
```

没有 `curl` 时可用：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/hynize/singbox-manager/main/install.sh)
```

安装完成后直接运行：

```bash
sbm
```

## 软件功能

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
- `TUIC v5` 生成链接默认自动跳过证书验证
- UUID 留空时自动生成
- 自动安装保活机制
- 自动生成节点分享链接
- 支持脚本更新、节点删除、服务重启、项目卸载

## 交互目录设计

主菜单：

```text
1. Install/Update core
2. Add node
3. View nodes
4. Delete node
5. Restart services
6. Status
7. Update script
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

## 目录结构

仓库目录：

```text
.
├─ install.sh
├─ sb.sh
├─ scripts/
│  └─ watchdog.sh
└─ README.md
```

服务器落地目录：

```text
/usr/local/bin/
├─ sbm
├─ sing-box
└─ cloudflared

/usr/local/etc/singbox-manager/
├─ config.json
├─ nodes.json
├─ certs/
├─ logs/
├─ runtime/
└─ watchdog.sh
```

## 实现方式

### 1. 安装层

- `install.sh` 只做 bootstrap。
- 自动拉取仓库中的 `sb.sh` 与 `watchdog.sh` 到目标服务器。
- 安装完成后直接执行 `sbm` 进入主菜单。

### 2. 命令层

- `sb.sh` 是项目主入口。
- 负责依赖安装、核心二进制安装、交互菜单、节点录入、配置生成、服务控制、更新和卸载。
- 节点元数据统一存储在 `nodes.json`，避免直接手工改大型 `config.json`。

### 3. 配置生成层

- 所有协议都先写入 `nodes.json`。
- `render_config` 会根据元数据动态生成完整的 `sing-box` 服务端配置。
- 每新增或删除节点后自动重建 `config.json` 并重启服务。
- 每个协议以单节点单 inbound 的方式生成，便于维护、删除和定位问题。

### 4. 分享链接层

- 每个节点创建后自动生成对应分享链接并回写到 `nodes.json`。
- `VLESS + Reality` 生成 `reality` 标准链接，包含 `pbk`、`sid`、`flow=xtls-rprx-vision`。
- `VLESS + WS + TLS` 生成带 `host`、`sni`、`path`、`allowInsecure=1` 的链接。
- `VLESS + Argo` 默认以 `443` 对外分享，`host/sni` 自动使用 Argo 实际域名。
- `TUIC v5` 自动追加 `allow_insecure=1`。
- `Hysteria2` 自动追加 `insecure=1`。
- `SOCKS5` 生成标准 `socks5://user:pass@host:port` 地址。

## 各协议实现说明

### VLESS + Reality

- 类型：`vless` inbound
- TLS：启用 `reality`
- 默认伪装域名：`www.apple.com`
- 自动生成：
  - UUID
  - Reality 密钥对
  - `short_id`
- 分享链接包含：
  - `security=reality`
  - `pbk`
  - `sid`
  - `fp=chrome`

### VLESS + WS + TLS

- 类型：`vless` inbound
- 传输：`ws`
- TLS：自签名证书
- 默认优选域名：`saas.sin.fan`
- 支持自定义：
  - 监听端口
  - 节点名称
  - UUID
  - 优选域名
  - `Host/SNI`
  - `WS Path`

### AnyTLS

- 类型：`anytls` inbound
- TLS：自签名证书
- 支持自定义密码与 SNI
- 适合轻量 TLS 伪装场景

### VLESS + Argo

- 类型：本地 `vless + ws`，由 `cloudflared` 对外暴露
- 默认优选域名：`saas.sin.fan`
- 支持两种模式：
  - 临时隧道
  - Token 固定隧道
- 临时隧道会自动解析 `trycloudflare` 域名并刷新分享链接
- Token 隧道可手动指定固定的 Argo 域名

### TUIC v5

- 类型：`tuic` inbound
- 默认启用：
  - `congestion_control = bbr`
  - `alpn = h3`
  - `heartbeat = 10s`
- UUID 留空自动生成
- 密码留空默认复用 UUID
- 分享链接默认跳过证书校验

### Hysteria2

- 类型：`hysteria2` inbound
- 默认启用 `h3`
- 自动生成密码
- 分享链接默认 `insecure=1`

### SOCKS5

- 类型：`socks` inbound
- 支持自定义用户名/密码
- 适合作为通用本地代理入口

## 自动保活设计

项目会同时保证 `sing-box` 主服务和 `cloudflared` 进程可恢复。

### systemd 环境

- 创建 `singbox-manager.service`
- 创建 `singbox-manager-watchdog.service`
- 创建 `singbox-manager-watchdog.timer`
- 定时器每分钟执行一次 watchdog

### 非 systemd 环境

- 使用 `cron` 每分钟执行一次 `watchdog.sh`
- 如果 `sing-box` 异常退出，则后台重新拉起

### watchdog 检查内容

- `sing-box` 进程是否存活
- `VLESS + Argo` 对应的 `cloudflared` 进程是否存活
- 临时 Argo 隧道重建后是否需要刷新域名与分享链接

## 默认值说明

- `VLESS + Argo` 优选域名：`saas.sin.fan`
- `VLESS + WS + TLS` 优选域名：`saas.sin.fan`
- `VLESS + Reality` 伪装域名：`www.apple.com`
- 其他 TLS 类协议默认 SNI：`www.bing.com`

## 使用建议

- `WS + TLS`、`AnyTLS`、`TUIC`、`Hysteria2` 默认使用自签名证书，客户端需允许跳过证书校验，或自行替换为正式证书。
- `Argo` 临时隧道的实际域名可能变化，重新进入 `sbm` 查看节点即可拿到最新地址。
- `saas.sin.fan` 只是默认优选域名，实际是否适合你的线路请自行测试。

## 适用场景

- 单机快速起节点
- 统一管理多个 `sing-box` 协议入口
- 需要菜单式操作，不想手工维护 JSON 配置
- 需要自动保活 `Argo + sing-box`

## 后续可扩展方向

- 域名证书替换为正式证书
- 订阅聚合输出
- 节点批量导出
- 多用户管理
- 端口转发与中转模式
