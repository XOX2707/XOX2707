<#
.SYNOPSIS
  检测本机代理 127.0.0.1:12334 能否连通 https://claude.ai
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Test-ClaudeProxy.ps1
  powershell -ExecutionPolicy Bypass -File .\Test-ClaudeProxy.ps1 -Port 7890
#>
param(
    [string]$ProxyHost = '127.0.0.1',
    [int]$Port = 12334,
    [string]$Url = 'https://claude.ai'
)

$proxy = "${ProxyHost}:${Port}"
Write-Host "== 1. TCP 端口检测 $proxy ==" -ForegroundColor Cyan
$tcp = Test-NetConnection $ProxyHost -Port $Port -WarningAction SilentlyContinue
if (-not $tcp.TcpTestSucceeded) {
    Write-Host "失败: $proxy 没有在监听，请确认代理软件已启动且端口正确。" -ForegroundColor Red
    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object LocalAddress -in '127.0.0.1','0.0.0.0','::' |
        Sort-Object LocalPort | Select-Object LocalAddress, LocalPort, OwningProcess |
        Format-Table -AutoSize
    exit 1
}
Write-Host "成功: 端口已开放" -ForegroundColor Green

$curl = Get-Command curl.exe -ErrorAction SilentlyContinue
foreach ($scheme in 'http', 'socks5h') {
    Write-Host "`n== 2. 通过 $scheme://$proxy 访问 $Url ==" -ForegroundColor Cyan
    if ($curl) {
        $out = & curl.exe -sS -o NUL -m 15 -x "$scheme://$proxy" `
            -w "HTTP %{http_code}  连接 %{time_connect}s  TLS %{time_appconnect}s  总计 %{time_total}s  出口IP %{remote_ip}" $Url 2>&1
        Write-Host $out
    } elseif ($scheme -eq 'http') {
        try {
            $r = Invoke-WebRequest $Url -Proxy "http://$proxy" -UseBasicParsing -TimeoutSec 15 -MaximumRedirection 0 -ErrorAction Stop
            Write-Host "HTTP $($r.StatusCode)"
        } catch {
            $code = $_.Exception.Response.StatusCode.value__
            if ($code) { Write-Host "HTTP $code" } else { Write-Host "失败: $($_.Exception.Message)" -ForegroundColor Red }
        }
    }
}

Write-Host "`n== 3. 出口地区（claude.ai 不支持部分地区） ==" -ForegroundColor Cyan
if ($curl) { & curl.exe -sS -m 15 -x "http://$proxy" https://claude.ai/cdn-cgi/trace 2>&1 | Select-String '^(ip|loc|colo)=' }

Write-Host @"

结果判读:
  HTTP 200/301/302/403(Cloudflare 验证)  -> 代理链路通，浏览器可用
  HTTP 000 / 超时 / 连接被重置              -> 端口通但代理上游不通，检查节点
  loc=CN/HK/RU 等不支持地区                 -> 链路通，但 claude.ai 会拒绝服务，请换节点
"@
