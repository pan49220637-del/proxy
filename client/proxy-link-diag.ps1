[CmdletBinding()]
param(
    [ValidateSet('Snapshot','XHTTP','HY2','AnyTLS')]
    [string]$Node = 'Snapshot',
    [ValidateRange(10,120)]
    [int]$CaptureSeconds = 30,
    [string]$KeyPath = (Join-Path $env:USERPROFILE '.ssh\siafeng-vps.pem'),
    [string]$V2rayRoot = 'D:\Program Files\v2rayN-windows-64\v2rayN-windows-64'
)

$ErrorActionPreference = 'Continue'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$ReportDir = Join-Path $PSScriptRoot "diagnostics\$Stamp-$($Node.ToLowerInvariant())"
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

$VpsA = '18.138.170.239'
$VpsB = '56.10.55.243'
$Expected = @{
    'xr.siafeng.xyz' = $VpsA
    'hy.siafeng.xyz' = $VpsB
    'at.siafeng.xyz' = $VpsB
}
$NodeInfo = @{
    XHTTP  = @{ Domain='xr.siafeng.xyz'; Vps=$VpsA; Capture='xhttp'; Transport='TCP'; RequiredCore='Xray' }
    HY2    = @{ Domain='hy.siafeng.xyz'; Vps=$VpsB; Capture='hy2'; Transport='UDP'; RequiredCore='sing_box' }
    AnyTLS = @{ Domain='at.siafeng.xyz'; Vps=$VpsB; Capture='anytls'; Transport='TCP'; RequiredCore='sing_box' }
}

function Save-Text {
    param([string]$Name, [object[]]$Value)
    $Value | Out-File -LiteralPath (Join-Path $ReportDir $Name) -Encoding utf8 -Width 500
}

function Invoke-Remote {
    param([string]$Ip, [string]$Command)
    & ssh.exe -o BatchMode=yes -o ConnectTimeout=10 -i $KeyPath "ubuntu@$Ip" $Command 2>&1
}

function Get-ActiveRuntime {
    $runtimePath = Join-Path $V2rayRoot 'binConfigs\config.json'
    if (-not (Test-Path -LiteralPath $runtimePath)) { return $null }
    try {
        $runtime = Get-Content -LiteralPath $runtimePath -Raw | ConvertFrom-Json
        $outbound = @($runtime.outbounds | Where-Object { $_.tag -eq 'proxy' } | Select-Object -First 1)
        if ($outbound.Count -eq 0) { $outbound = @($runtime.outbounds | Select-Object -First 1) }
        if ($outbound.Count -eq 0) { return $null }
        $item = $outbound[0]
        $protocol = if ($item.type) { $item.type } else { $item.protocol }
        $server = if ($item.server) { $item.server } else { $item.settings.address }
        $port = if ($item.server_port) { $item.server_port } else { $item.settings.port }
        $network = if ($item.transport.type) { $item.transport.type } else { $item.streamSettings.network }
        $security = if ($item.tls.enabled) { 'tls' } elseif ($item.streamSettings.security) { $item.streamSettings.security } else { '' }
        [pscustomobject]@{ Protocol=$protocol; Server=$server; Port=$port; Network=$network; Security=$security; Updated=(Get-Item -LiteralPath $runtimePath).LastWriteTime }
    } catch {
        return $null
    }
}

$Summary = [System.Collections.Generic.List[string]]::new()
$Summary.Add("诊断时间: $(Get-Date -Format o)")
$Summary.Add("模式: $Node")

if (-not (Test-Path -LiteralPath $KeyPath)) {
    $Summary.Add("[阻断] SSH 诊断密钥不存在: $KeyPath")
    Save-Text 'SUMMARY.txt' $Summary
    throw "SSH diagnostic key not found: $KeyPath"
}

Write-Host "[1/6] 采集 Windows 网络状态..." -ForegroundColor Cyan
$local = @()
$local += "Time: $(Get-Date -Format o)"
$local += "Computer: $env:COMPUTERNAME"
$local += Get-NetIPConfiguration | Format-List InterfaceAlias,InterfaceDescription,IPv4Address,IPv6Address,IPv4DefaultGateway,DNSServer | Out-String
$local += ipconfig /all
$local += route print
Save-Text 'client-network.txt' $local

Write-Host "[2/6] 核验公共 DNS..." -ForegroundColor Cyan
$dnsLines = @()
$DnsOk = $true
$DnsFakeIp = $false
foreach ($name in $Expected.Keys) {
    try {
        $answer = @(Resolve-DnsName -Name $name -Type A -Server 1.1.1.1 -DnsOnly -ErrorAction Stop | Where-Object Type -eq 'A' | Select-Object -ExpandProperty IPAddress)
        $dnsLines += "$name A=$($answer -join ',') expected=$($Expected[$name])"
        $fakeAnswer = @($answer | Where-Object { $_ -match '^198\.(18|19)\.' })
        if ($fakeAnswer.Count -gt 0) {
            $DnsFakeIp = $true
            $dnsLines += "$name NOTE=v2rayN/TUN fake-IP detected; use server-side DNS result as public-DNS evidence"
        } elseif ($answer -notcontains $Expected[$name]) {
            $DnsOk = $false
        }
        $aaaa = @(Resolve-DnsName -Name $name -Type AAAA -Server 1.1.1.1 -DnsOnly -ErrorAction SilentlyContinue | Where-Object Type -eq 'AAAA' | Select-Object -ExpandProperty IPAddress)
        $dnsLines += "$name AAAA=$(if($aaaa){$aaaa -join ','}else{'<none>'})"
    } catch {
        $DnsOk = $false
        $dnsLines += "$name DNS_ERROR=$($_.Exception.Message)"
    }
}
Save-Text 'client-dns.txt' $dnsLines
if ($DnsOk -and -not $DnsFakeIp) { $Summary.Add('[PASS] 客户端看到三个域名的预期 A 记录') }
elseif ($DnsOk -and $DnsFakeIp) { $Summary.Add('[INFO] 客户端 DNS 被 v2rayN/TUN Fake-IP 接管；公共解析改由两台 VPS 快照交叉核验') }
else { $Summary.Add('[故障层 L2] DNS 记录错误或解析失败') }

Write-Host "[3/6] 采集两台 VPS 快照..." -ForegroundColor Cyan
$aSnapshot = Invoke-Remote $VpsA 'sudo /usr/local/sbin/proxy-diag'
$bSnapshot = Invoke-Remote $VpsB 'sudo /usr/local/sbin/proxy-diag'
Save-Text 'server-a.txt' $aSnapshot
Save-Text 'server-b.txt' $bSnapshot
if (($aSnapshot -match 'Configuration OK') -and ($aSnapshot -match 'active')) { $Summary.Add('[PASS] VPS-A Xray/Nginx 基线检查有响应') } else { $Summary.Add('[故障层 L5-L7] VPS-A 服务或配置检查异常，查看 server-a.txt') }
if (($bSnapshot -match 'sing-box version') -and ($bSnapshot -match 'active')) { $Summary.Add('[PASS] VPS-B sing-box 基线检查有响应') } else { $Summary.Add('[故障层 L5-L7] VPS-B 服务或配置检查异常，查看 server-b.txt') }

Write-Host "[4/6] 读取当前 v2rayN 日志..." -ForegroundColor Cyan
$runtimeBefore = Get-ActiveRuntime
if ($runtimeBefore) {
    Save-Text 'v2rayn-active-runtime.txt' ($runtimeBefore | Format-List | Out-String)
    $Summary.Add("[客户端当前运行配置] protocol=$($runtimeBefore.Protocol) server=$($runtimeBefore.Server) port=$($runtimeBefore.Port) network=$($runtimeBefore.Network) security=$($runtimeBefore.Security)")
} else {
    $Summary.Add('[客户端状态] 未找到 v2rayN 当前运行配置；可能尚未启动核心')
}
$logDir = Join-Path $V2rayRoot 'guiLogs'
$recentLogs = @(Get-ChildItem -LiteralPath $logDir -Filter '*.txt' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 7)
$clientLog = @()
if ($recentLogs.Count -gt 0) {
    foreach ($log in $recentLogs) {
        $clientLog += "Source: $($log.FullName)"
        $clientLog += Get-Content -LiteralPath $log.FullName -Tail 2000 | Select-String -Pattern 'ERROR|WARN|fail|timeout|EOF|handshake|unsupported|不支持|Siafeng|XHTTP|Hysteria|AnyTLS' -CaseSensitive:$false | ForEach-Object Line
    }
} else {
    $clientLog += 'No v2rayN gui log found.'
}
Save-Text 'v2rayn-relevant.log' $clientLog
if ($clientLog -match "Siafeng-XHTTP-Reality.*sing_box.*xhttp") {
    $Summary.Add('[客户端配置故障/历史日志] XHTTP 节点曾被分配给 sing_box；请在 v2rayN 将该节点核心改为 Xray Core 后重测')
}

if ($Node -ne 'Snapshot') {
    $info = $NodeInfo[$Node]
    Write-Host "[5/6] 开始 $CaptureSeconds 秒联动窗口：$Node / $($info.Domain) / $($info.Transport)" -ForegroundColor Yellow
    Write-Host "现在请在 v2rayN 里双击对应 Siafeng 节点设为活动服务器，并连续打开网页或测速。" -ForegroundColor Yellow
    [void](Read-Host '切换完成后按回车，脚本将开始服务端抓包和 10 MB 自动测速')

    $runtimeSelected = Get-ActiveRuntime
    if ($runtimeSelected -and $runtimeSelected.Server -ne $info.Domain) {
        $Summary.Add("[操作提醒] 当前活动服务器为 $($runtimeSelected.Server)，不是 $($info.Domain)；请正确切换后重新运行")
    }

    $tcpResult = $null
    if ($info.Transport -eq 'TCP') {
        $tcpResult = Test-NetConnection -ComputerName $info.Vps -Port 443 -InformationLevel Detailed
        Save-Text 'client-port-test.txt' ($tcpResult | Format-List * | Out-String)
        if ($tcpResult.TcpTestSucceeded) { $Summary.Add("[PASS] 客户端到 $($info.Domain):443 TCP 可达") } else { $Summary.Add('[故障层 L3-L4] 客户端 TCP/443 不可达，查本地网络、路由、云安全组') }
    } else {
        Save-Text 'client-port-test.txt' @('HY2 使用 UDP；不使用 Test-NetConnection 的 TCP 结果判定。以服务端抓包为准。')
    }

    $captureOut = Join-Path $ReportDir "server-capture-$($Node.ToLowerInvariant()).txt"
    $captureErr = Join-Path $ReportDir "server-capture-$($Node.ToLowerInvariant()).err.txt"
    $remote = "sudo /usr/local/sbin/proxy-capture $($info.Capture) $CaptureSeconds"
    $sshArgs = @('-o','BatchMode=yes','-o','ConnectTimeout=10','-i',$KeyPath,"ubuntu@$($info.Vps)",$remote)
    $captureProcess = Start-Process -FilePath 'ssh.exe' -ArgumentList $sshArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput $captureOut -RedirectStandardError $captureErr

    $localCaptureProcess = $null
    $dumpcap = 'C:\Program Files\Wireshark\dumpcap.exe'
    $tshark = 'C:\Program Files\Wireshark\tshark.exe'
    $localPcap = Join-Path $ReportDir "client-$($Node.ToLowerInvariant()).pcapng"
    $localCaptureErr = Join-Path $ReportDir 'client-wireshark-capture.err.txt'
    if (Test-Path -LiteralPath $dumpcap) {
        $captureArgs = @()
        $physicalRoute = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -ne '0.0.0.0' } | Sort-Object RouteMetric,InterfaceMetric | Select-Object -First 1
        if ($physicalRoute) {
            $physicalAdapter = Get-NetAdapter -InterfaceIndex $physicalRoute.ifIndex -ErrorAction SilentlyContinue
            if ($physicalAdapter) {
                $physicalDevice = "\Device\NPF_$($physicalAdapter.InterfaceGuid)"
                $captureArgs += @('-i',$physicalDevice,'-f',"`"host $($info.Vps) and port 443`"",'-s','128')
            }
        }
        $tunAdapter = Get-NetAdapter -Name 'xray_tun' -ErrorAction SilentlyContinue
        if ($tunAdapter) {
            $tunDevice = "\Device\NPF_$($tunAdapter.InterfaceGuid)"
            $captureArgs += @('-i',$tunDevice,'-f','"port 443"','-s','128')
        }
        if ($captureArgs.Count -gt 0) {
            $captureArgs += @('-a',"duration:$CaptureSeconds",'-w',$localPcap)
            $localCaptureProcess = Start-Process -FilePath $dumpcap -ArgumentList $captureArgs -WindowStyle Hidden -PassThru -RedirectStandardError $localCaptureErr
        }
    } else {
        $Summary.Add('[本地抓包] 未找到 Wireshark dumpcap.exe，跳过本机 pcapng')
    }

    Start-Sleep -Seconds 2
    $throughput = & curl.exe --proxy socks5h://127.0.0.1:10808 -L --max-time 45 -o NUL -sS -w 'http=%{http_code} bytes=%{size_download} seconds=%{time_total} avg_Bps=%{speed_download}' 'https://speed.cloudflare.com/__down?bytes=10000000' 2>&1
    Save-Text 'client-throughput.txt' $throughput
    if (($LASTEXITCODE -eq 0) -and (($throughput -join ' ') -match 'avg_Bps=([0-9.]+)')) {
        $speedMB = [math]::Round(([double]$Matches[1] / 1MB), 2)
        $Summary.Add("[吞吐样本] 当前节点经本地 SOCKS 10808 下载约 $speedMB MB/s；结果见 client-throughput.txt")
    } else {
        $Summary.Add('[吞吐故障] 通过本地 SOCKS 10808 的自动下载失败；查看 client-throughput.txt 与 v2rayn-relevant.log')
    }

    $pingText = Test-Connection -ComputerName $info.Domain -Count 6 -ErrorAction SilentlyContinue | Format-Table -AutoSize | Out-String
    Save-Text 'client-ping.txt' $pingText
    Wait-Process -Id $captureProcess.Id -Timeout ($CaptureSeconds + 15) -ErrorAction SilentlyContinue
    if (-not $captureProcess.HasExited) { Stop-Process -Id $captureProcess.Id -Force }
    if ($localCaptureProcess) {
        Wait-Process -Id $localCaptureProcess.Id -Timeout 10 -ErrorAction SilentlyContinue
        if (-not $localCaptureProcess.HasExited) { Stop-Process -Id $localCaptureProcess.Id -Force }
        if ((Test-Path -LiteralPath $localPcap) -and ((Get-Item -LiteralPath $localPcap).Length -gt 128)) {
            $Summary.Add("[本地抓包 PASS] Wireshark pcapng 已生成：$localPcap")
            if (Test-Path -LiteralPath $tshark) {
                $wiresharkSummary = & $tshark -r $localPcap -q -z io,stat,0 2>&1
                Save-Text 'client-wireshark-summary.txt' $wiresharkSummary
            }
        } else {
            $Summary.Add('[本地抓包] Wireshark 未捕获到目标流量；查看 client-wireshark-capture.err.txt')
        }
    }

    $packetCount = 0
    if (Test-Path -LiteralPath $captureOut) {
        $packetCount = @(Select-String -LiteralPath $captureOut -Pattern ' IP | IP6 ' -ErrorAction SilentlyContinue).Count
    }
    $runtimeAfter = Get-ActiveRuntime
    if ($runtimeAfter -and $runtimeAfter.Server -ne $info.Domain) {
        $Summary.Add("[操作提醒] 抓包结束时活动服务器为 $($runtimeAfter.Server)，不是 $($info.Domain)；本次结果不能代表 $Node 节点")
    }
    if ($packetCount -eq 0) {
        $Summary.Add("[联动抓包] 服务端未看到 $($info.Transport)/443 流量：节点未实际触发，或故障位于客户端/DNS/路由/安全组/运营商路径")
    } else {
        $Summary.Add("[联动抓包 PASS] 服务端看到 $packetCount 行 $($info.Transport)/443 数据；链路已到服务器")
        if ($Node -eq 'HY2') { $Summary.Add('[后续判定] 若仍中断/慢，重点查 UDP 丢包、QoS 与 MTU；不要先改密码或重装服务') }
        if ($Node -eq 'AnyTLS') { $Summary.Add('[后续判定] 若仍失败，结合 sing-box 日志查 TLS SNI、密码与客户端核心') }
        if ($Node -eq 'XHTTP') { $Summary.Add('[后续判定] 若仍失败，结合 Xray 日志查 UUID、REALITY 公钥/shortId 与 XHTTP path/mode') }
    }
} else {
    Write-Host '[5/6] Snapshot 模式不抓包。' -ForegroundColor Cyan
}

Write-Host "[6/6] 生成结论..." -ForegroundColor Cyan
$Summary.Add("报告目录: $ReportDir")
Save-Text 'SUMMARY.txt' $Summary

Write-Host ''
Write-Host '诊断完成：' -ForegroundColor Green
$Summary | ForEach-Object { Write-Host $_ }
Write-Host "完整报告: $ReportDir" -ForegroundColor Green
