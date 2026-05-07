# Singbox Manager

一个面向常用 `sing-box` 场景的交互式管理项目，目标是把“安装核心、添加节点、生成链接、自动保活、日常维护”整合为一个可发布、可校验、可运维的 Bash 项目。

## 一键地址

发布版安装脚本：

```text
https://github.com/hynize/singbox-manager/releases/download/v0.2.6/install.sh
```

快速安装：

```bash
bash <(curl -fsSL https://github.com/hynize/singbox-manager/releases/download/v0.2.6/install.sh)
```

更安全的两步安装：

```bash
curl -fsSLO https://github.com/hynize/singbox-manager/releases/download/v0.2.6/install.sh
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
- `TUIC v5` 在自签证书模式下默认附带跳过证书验证参数
- UUID 留空时自动生成
- 支持自动保活 `sing-box + cloudflared`
- 支持日志轮转
- 支持 `OpenRC`
- 支持发布版自更新

## 项目结构

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

## 发布流程

1. 更新代码与 `VERSION`
2. 运行 `bash scripts/build-release-bundle.sh`
3. 上传 `singbox-manager-<version>.tar.gz` 和 `checksums.txt` 到 GitHub Release
4. 发布同版本的 `install.sh`

## 当前固定版本

- `sing-box`: `v1.13.8`
- `cloudflared`: `2026.3.0`

详细版本与校验和位于 `metadata/upstream.env`。
