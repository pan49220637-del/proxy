# Windows v2rayN 与双 VPS 联动诊断

这是一套独立诊断工具，不修改 v2rayN、不注入插件，也不接触节点密钥。Windows 脚本只读当前 v2rayN 运行配置和日志，并通过 SSH 调用两台 VPS 上的只读快照与限时抓包脚本。

## 已部署环境

- Windows：`client/proxy-link-diag.ps1`
- Windows 双击入口：`client/运行联动诊断.cmd`
- Windows 本地抓包：自动调用已安装的 Wireshark `dumpcap.exe` 和 `tshark.exe`
- VPS-A、VPS-B：`/usr/local/sbin/proxy-diag`、`/usr/local/sbin/proxy-capture`
- SSH 私钥默认路径：`%USERPROFILE%\.ssh\siafeng-vps.pem`，私钥不得提交到仓库
- v2rayN 默认路径：`D:\Program Files\v2rayN-windows-64\v2rayN-windows-64`

服务端重装工具：

```bash
sudo bash server/install-tools.sh
```

## 使用方法

正常巡检直接双击 `运行联动诊断.cmd`，输入 `0`。出现某个节点连不上、中断或速度异常时，重新运行并选择对应模式：

```text
1 = XHTTP + REALITY（VPS-A，TCP/443）
2 = Hysteria2（VPS-B，UDP/443）
3 = AnyTLS（VPS-B，TCP/443）
```

看到提示后，在 v2rayN 中把对应的 Siafeng 节点设为活动服务器，再回到窗口按回车。脚本会执行 10 MB 自动吞吐测试，并同时采集：

- Windows 地址、网关、DNS、路由与连通性
- v2rayN 当前生成的运行配置摘要（不输出密码和密钥）
- v2rayN 最近错误日志
- 通过本地 SOCKS `127.0.0.1:10808` 的真实下载吞吐样本
- 两台 VPS 的服务状态、监听端口、防火墙、证书、系统资源和内核日志
- 对应 VPS 的 TCP/443 或 UDP/443 限时抓包证据
- 本机物理网卡与 `xray_tun` 的 128-byte snaplen `pcapng`，可直接用 Wireshark 打开

报告写入脚本旁的 `diagnostics/时间-模式/`，先看 `SUMMARY.txt`。

也可从 PowerShell 运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\client\proxy-link-diag.ps1 -Node Snapshot
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\client\proxy-link-diag.ps1 -Node HY2 -CaptureSeconds 30
```

路径不同时使用参数覆盖：

```powershell
.\client\proxy-link-diag.ps1 -Node XHTTP -KeyPath C:\keys\vps.pem -V2rayRoot C:\apps\v2rayN
```

## 快速判断

| 证据 | 结论 |
|---|---|
| Windows DNS 错误，VPS 公共 DNS 正确 | 本机 DNS/TUN/劫持问题 |
| TCP/443 不可达，服务端抓不到包 | 本地网络、路由、云安全组或运营商路径 |
| HY2 抓不到 UDP/443，但两个 TCP 协议正常 | UDP 被限速/阻断、QUIC 丢包或 MTU 问题 |
| 服务端能持续看到包，客户端仍握手失败 | 核心、SNI、密码、UUID、REALITY 或传输参数不一致 |
| 抓包结束时活动服务器不是目标域名 | 本轮未正确切换节点，结果不能代表该节点 |
| 服务进程、监听端口或配置检查失败 | 对应 VPS 服务端故障 |

## 当前已发现的客户端问题

2026-09-27 的 v2rayN 日志记录：`Siafeng-XHTTP-Reality` 曾被分配给 `sing_box`，而该核心不支持 `xhttp`。该节点必须使用 **Xray Core**；HY2 和 AnyTLS 使用 **sing-box**。

延迟测试只说明握手耗时，不等于真实吞吐。v2rayN 列表中一次 `0.0/0.1 MB/s` 也不能单独证明服务端带宽故障；应在联动抓包模式下持续下载后，结合丢包、服务端资源和协议差异判断。

2026-09-28 实测当前 HY2：10 MB 自动下载约 `3.51 MB/s`，本机 Wireshark 捕获 8,396 包，VPS-B 捕获 8,637 行 UDP/443，WLAN 抓包统计无丢包。该样本说明当时客户端、UDP 路径和服务端均实际有流量，不能用列表中的瞬时 `2.4 MB/s` 单独判定服务器故障。

## 安全边界

- 仓库与诊断报告不得包含 SSH 私钥、UUID、REALITY 私钥、shortId、HY2/AnyTLS 密码或完整分享链接。
- VPS 抓包仅保留文本包头；本机 Wireshark 抓包最长 120 秒且 snaplen 为 128 字节，报告目录不得公开上传。
- `proxy-diag` 只验证配置，不输出完整服务端配置。
