# 运维与故障排查

## 1. 30 秒分流

分别测试 XHTTP、HY2、AnyTLS：

| XHTTP | HY2 | AnyTLS | 优先排查 |
|---|---|---|---|
| 正常 | 异常 | 正常 | UDP/443、QUIC、MTU、运营商 UDP |
| 正常 | 异常 | 异常 | VPS-B、DNS、路由、安全组 |
| 异常 | 正常 | 正常 | VPS-A、Xray、REALITY、TCP/443 |
| 异常 | 异常 | 正常 | HY2 专属故障，重点查 UDP/443 |
| 异常 | 正常 | 异常 | AnyTLS、TCP/TLS、密码或 SNI |
| 异常 | 异常 | 异常 | 本地网络、DNS、两台 VPS 可达性 |

先定位故障层，再改配置；不要同时改协议、端口、SNI、混淆和 MTU。

## 2. DNS

```bash
dig +short A xr.siafeng.xyz @1.1.1.1
dig +short A hy.siafeng.xyz @1.1.1.1
dig +short A at.siafeng.xyz @1.1.1.1
dig +short AAAA xr.siafeng.xyz @1.1.1.1
```

期望三个 A 记录分别匹配生产 IP，AAAA 为空。

## 3. VPS-A 检查

```bash
systemctl status xray nginx --no-pager
xray run -test -config /usr/local/etc/xray/config.json
nginx -t
ss -lntp | grep -E ':80|:443|:8443'
journalctl -u xray -n 100 --no-pager
```

重点判定：

```text
TCP/443 -> xray
127.0.0.1:8443 -> nginx
```

若日志出现 `invalid request user id`，先检查服务端是否错误使用了 `settings.users`；本基线要求 `settings.clients`。

## 4. VPS-B 检查

```bash
systemctl status sing-box --no-pager
sing-box check -c /etc/sing-box/config.json
ss -lntup | grep ':443'
journalctl -u sing-box -n 100 --no-pager
```

必须同时看到：

```text
TCP/443 -> sing-box
UDP/443 -> sing-box
```

若 AnyTLS 正常但 HY2 失败，优先查云安全组 UDP/443、运营商 UDP 与路径 MTU。

## 5. 证书与续期

```bash
certbot certificates
systemctl status certbot.timer --no-pager
certbot renew --dry-run
```

VPS-A：

```bash
openssl x509 -in /etc/letsencrypt/live/xr.siafeng.xyz/fullchain.pem \
  -noout -subject -issuer -dates -ext subjectAltName
```

VPS-B：

```bash
openssl x509 -in /etc/sing-box/tls/fullchain.pem \
  -noout -subject -issuer -dates -ext subjectAltName
namei -l /etc/sing-box/tls/privkey.pem
```

## 6. 抓包定位

```bash
# VPS-A
tcpdump -ni any tcp port 443

# VPS-B / Hysteria2
tcpdump -ni any udp port 443

# VPS-B / AnyTLS
tcpdump -ni any tcp port 443
```

客户端发起连接时完全没有包，问题位于服务器之前：DNS、路由、防火墙、云安全组或运营商路径。

## 7. 安全变更流程

```bash
# Xray
cp /usr/local/etc/xray/config.json /usr/local/etc/xray/config.json.$(date +%Y%m%d-%H%M%S).bak
xray run -test -config /usr/local/etc/xray/config.json && systemctl restart xray

# sing-box
cp /etc/sing-box/config.json /etc/sing-box/config.json.$(date +%Y%m%d-%H%M%S).bak
sing-box check -c /etc/sing-box/config.json && systemctl restart sing-box
```

不要在没有验证回滚点的情况下覆盖工作配置。
