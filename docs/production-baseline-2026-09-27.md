# 生产部署基线（2026-09-27）

## 1. 状态

部署与跨 VPS 实连验收均已通过。

| 链路 | 域名 | VPS | 监听 | 服务版本 | 验收 |
|---|---|---|---|---|---|
| VLESS + XHTTP + REALITY | `xr.siafeng.xyz` | `18.138.170.239` | TCP/443 | Xray 26.3.27 | PASS |
| Hysteria2 | `hy.siafeng.xyz` | `56.10.55.243` | UDP/443 | sing-box 1.14.2 | PASS |
| AnyTLS | `at.siafeng.xyz` | `56.10.55.243` | TCP/443 | sing-box 1.14.2 | PASS |

两台服务器均为 Ubuntu 24.04.4 LTS ARM64，内核拥塞控制为 BBR，默认队列为 `fq`。

DNS 为 Cloudflare DNS only（灰云），仅配置 A 记录，不配置 AAAA。

## 2. 拓扑

```text
Client
├── xr.siafeng.xyz:443/TCP
│   └── Xray / VLESS + XHTTP + REALITY
│       └── target 127.0.0.1:8443 / Nginx HTTPS
└── VPS-B 56.10.55.243
    ├── hy.siafeng.xyz:443/UDP -> Hysteria2
    └── at.siafeng.xyz:443/TCP -> AnyTLS
```

VPS-A 的 `8443` 仅监听 `127.0.0.1`，不对公网开放。

## 3. DNS 基线

```text
xr.siafeng.xyz  A  18.138.170.239
hy.siafeng.xyz  A  56.10.55.243
at.siafeng.xyz  A  56.10.55.243
```

Cloudflare Proxy status 必须为 `DNS only`。

## 4. VPS-A 基线

服务：

```text
xray.service    active/enabled
nginx.service   active/enabled
```

配置路径：

```text
/usr/local/etc/xray/config.json
/etc/nginx/sites-available/xr.conf
/etc/letsencrypt/live/xr.siafeng.xyz/
/root/proxy-secrets.env
/root/xray-client.json
```

关键结构：

```text
protocol = vless
settings.clients[]
decryption = none
network = xhttp
xhttp mode = auto
xhttp path = /assets/v1/sync
security = reality
target = 127.0.0.1:8443
serverNames = [xr.siafeng.xyz]
```

注意：服务端 VLESS 用户字段必须使用 `settings.clients`。曾使用 `settings.users` 时配置检查仍可通过，但 UUID 未注册，真实连接报 `invalid request user id`。

Ubuntu ARM64 当前 Nginx 包不接受独立的 `http2 on;` 指令，本基线未启用该非必需指令；这不影响 REALITY 的本地 TLS target。

## 5. VPS-B 基线

服务：

```text
sing-box.service active/enabled
```

配置路径：

```text
/etc/sing-box/config.json
/etc/sing-box/tls/fullchain.pem
/etc/sing-box/tls/privkey.pem
/etc/letsencrypt/live/hy.siafeng.xyz/
/root/proxy-secrets.env
/root/sing-box-clients.json
```

证书先由 Certbot 写入 `/etc/letsencrypt`，再复制到 `/etc/sing-box/tls`：

```text
fullchain.pem  root:sing-box 0644
privkey.pem    root:sing-box 0640
```

这样不需要放宽整个 `/etc/letsencrypt` 目录树的权限。

Hysteria2 基线：

```text
bbr_profile = standard
未设置 up_mbps/down_mbps
未启用 obfs、port hopping、realm 或自定义 QUIC 参数
```

AnyTLS 使用默认 padding/session 行为。

## 6. 防火墙

VPS-A UFW：

```text
22/tcp ALLOW
80/tcp ALLOW
443/tcp ALLOW
```

VPS-B UFW：

```text
22/tcp ALLOW
80/tcp ALLOW
443/tcp ALLOW
443/udp ALLOW
```

云安全组也必须保持相同端口。特别不要遗漏 VPS-B 的 UDP/443。

## 7. 证书

证书由 Certbot + Let's Encrypt 签发：

- `xr.siafeng.xyz`：单域名证书。
- `hy.siafeng.xyz`：SAN 同时包含 `hy.siafeng.xyz` 与 `at.siafeng.xyz`。

当前证书有效期截至 2026-12-26，`certbot.timer` 负责自动续期。

部署钩子：

```text
VPS-A /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
VPS-B /etc/letsencrypt/renewal-hooks/deploy/reload-sing-box.sh
```

VPS-B 钩子会先复制新证书并保持最小读取权限，然后检查配置并重启 sing-box。

## 8. 客户端基线

已确认 v2rayN 7.24.8 可承载三条协议：

- XHTTP + REALITY 使用 Xray Core。
- Hysteria2 与 AnyTLS 使用 sing-box Core。

完整客户端凭据只保存在用户本地交付文件中，不进入本仓库。

推荐优先级：

```text
Hysteria2 -> XHTTP + REALITY -> AnyTLS
```

## 9. 验收证据

服务器侧：

- `xray run -test`：PASS。
- `sing-box check`：PASS。
- Xray、Nginx、sing-box：均为 active。
- VPS-A TCP/443 由 Xray 监听，127.0.0.1:8443 由 Nginx 监听。
- VPS-B TCP/443 与 UDP/443 均由 sing-box 监听。

真实协议测试：

- 从 VPS-B 经 XHTTP + REALITY 访问 Cloudflare trace，出口 IP 为 `18.138.170.239`：PASS。
- 从 VPS-A 经 Hysteria2 访问 Cloudflare trace，出口 IP 为 `56.10.55.243`：PASS。
- 从 VPS-A 经 AnyTLS 访问 Cloudflare trace，出口 IP 为 `56.10.55.243`：PASS。

此结果验证的是完整代理协议链路，不只是端口可达或服务进程存活。

## 10. 变更规则

1. 永远先备份配置。
2. 每次只修改一个变量。
3. 先执行配置检查，再重启服务。
4. 同时在 Wi-Fi 与 4G/5G 上验证。
5. 不把生产密钥、客户端分享链接或 SSH 私钥提交到 Git。
