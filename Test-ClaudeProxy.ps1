<#
.SYNOPSIS
  检测本机代理 127.0.0.1:12334 能否连通网页版 claude.ai 与 api.anthropic.com
.DESCRIPTION
  依次检查:
    1. Windows 系统代理 (HKCU Internet Settings 的 ProxyEnable / ProxyServer)
    2. 代理端口 TCP 监听                  (Test-NetConnection 127.0.0.1 -Port 12334)
    3. 经 http / socks5h 代理访问 claude.ai (curl.exe -x ... -I https://claude.ai)
    4. 出口地区                            (curl.exe -x ... https://claude.ai/cdn-cgi/trace)
    5. 经代理访问 API                      (curl.exe -x ... -I https://api.anthropic.com)
  全部通过时退出码为 0，否则为 1。
  -Hook 供 Claude Code SessionStart 钩子使用：只输出一段 JSON 摘要。
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Test-ClaudeProxy.ps1
  powershell -ExecutionPolicy Bypass -File .\Test-ClaudeProxy.ps1 -Port 7890
  powershell -ExecutionPolicy Bypass -File .\Test-ClaudeProxy.ps1 -Hook
#>
param(
    [string]$ProxyHost = '127.0.0.1',
    [int]$Port = 12334,
    [int]$TimeoutSec = 10,
    [switch]$Hook
)

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$proxy = "${ProxyHost}:${Port}"
$unsupported = 'CN', 'HK', 'MO', 'RU', 'BY', 'KP', 'IR', 'SY', 'CU'
$results = New-Object System.Collections.Generic.List[object]

function Section($title) { if (-not $Hook) { Write-Host "`n== $title ==" -ForegroundColor Cyan } }
function Add-Result($name, [bool]$ok, $detail) {
    $results.Add([pscustomobject]@{ Name = $name; Ok = $ok; Detail = $detail })
    if (-not $Hook) {
        $color = if ($ok) { 'Green' } else { 'Red' }
        Write-Host ("{0} {1}: {2}" -f $(if ($ok) { '[通过]' } else { '[失败]' }), $name, $detail) -ForegroundColor $color
    }
}
# 经代理发 HEAD 请求，返回最后一个 HTTP 状态码与响应头文本
function Invoke-ProxyHead($scheme, $url) {
    $out = (& curl.exe -sS -I -m $TimeoutSec -x "${scheme}://$proxy" $url 2>&1) -join "`n"
    $codes = [regex]::Matches($out, '(?m)^HTTP/\S+ (\d{3})') | ForEach-Object { [int]$_.Groups[1].Value }
    [pscustomobject]@{ Code = $(if ($codes) { @($codes)[-1] } else { 0 }); Raw = $out }
}

# 1. 系统代理
Section "1. Windows 系统代理"
$is = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
$enabled = $is.ProxyEnable -eq 1
$server = "$($is.ProxyServer)"
# ProxyServer 可能是 "host:port" 或 "http=host:port;https=host:port"
$matchesProxy = @($server -split ';' | ForEach-Object { ($_ -split '=', 2)[-1].Trim() }) -contains $proxy
Add-Result '系统代理' ($enabled -and $matchesProxy) "ProxyEnable=$([int]$is.ProxyEnable) ProxyServer=$server"

# 2. TCP 端口
Section "2. TCP 端口 $proxy"
$tcp = New-Object System.Net.Sockets.TcpClient
try { $listening = $tcp.ConnectAsync($ProxyHost, $Port).Wait(3000) -and $tcp.Connected } catch { $listening = $false } finally { $tcp.Close() }
Add-Result '代理端口' $listening $(if ($listening) { "$proxy 正在监听" } else { "$proxy 未监听，请确认代理软件已启动且端口正确" })

$curl = Get-Command curl.exe -ErrorAction SilentlyContinue
if (-not $curl) {
    Add-Result 'curl.exe' $false '未找到 curl.exe，无法进行 HTTP 检测'
} elseif ($listening) {
    # 3. claude.ai 网页版 (http 与 socks5h 两种代理协议)
    foreach ($scheme in 'http', 'socks5h') {
        Section "3. 经 ${scheme}://$proxy 访问 https://claude.ai"
        $r = Invoke-ProxyHead $scheme 'https://claude.ai'
        $challenge = $r.Raw -match '(?mi)^cf-mitigated:\s*challenge'
        $ok = $r.Code -in 200, 301, 302, 307, 308 -or ($r.Code -eq 403 -and $challenge)
        $detail = "HTTP $($r.Code)" + $(if ($challenge) { ' (Cloudflare 人机验证，浏览器可自动通过)' } elseif ($r.Code -eq 0) { ' (超时或连接被重置，检查代理节点)' } else { '' })
        Add-Result "claude.ai ($scheme)" $ok $detail
    }

    # 4. 出口地区
    Section "4. 出口地区 (claude.ai/cdn-cgi/trace)"
    $trace = (& curl.exe -sS -m $TimeoutSec -x "http://$proxy" 'https://claude.ai/cdn-cgi/trace' 2>&1) -join "`n"
    $loc = if ($trace -match '(?m)^loc=(\w+)') { $Matches[1] } else { '' }
    $ip = if ($trace -match '(?m)^ip=(\S+)') { $Matches[1] } else { '?' }
    $colo = if ($trace -match '(?m)^colo=(\w+)') { $Matches[1] } else { '?' }
    $ok = $loc -and $loc -notin $unsupported
    Add-Result '出口地区' $ok $(if ($loc) { "loc=$loc ip=$ip colo=$colo" + $(if (-not $ok) { ' (claude.ai 不支持该地区，请换节点)' } else { '' }) } else { '无法获取 trace' })

    # 5. API
    Section "5. 经 http://$proxy 访问 https://api.anthropic.com"
    $r = Invoke-ProxyHead 'http' 'https://api.anthropic.com'
    Add-Result 'api.anthropic.com' ($r.Code -gt 0) $(if ($r.Code -gt 0) { "HTTP $($r.Code) (服务器已响应；根路径 404 属正常)" } else { '无响应 (超时或连接被重置)' })
}

$failed = @($results | Where-Object { -not $_.Ok })
$summary = ($results | ForEach-Object { "$(if ($_.Ok) { '[OK]' } else { '[FAIL]' }) $($_.Name): $($_.Detail)" }) -join "`n"

if ($Hook) {
    $head = if ($failed.Count -eq 0) { "代理检测通过 ($proxy)" } else { "代理检测失败 $($failed.Count) 项 ($proxy)" }
    $msg = if ($failed.Count -eq 0) { $head } else { "$head`n" + (($failed | ForEach-Object { "[FAIL] $($_.Name): $($_.Detail)" }) -join "`n") }
    [pscustomobject]@{
        systemMessage      = $msg
        hookSpecificOutput = [pscustomobject]@{ hookEventName = 'SessionStart'; additionalContext = "Test-ClaudeProxy.ps1 结果:`n$summary" }
    } | ConvertTo-Json -Depth 3 -Compress
    exit 0
}
Write-Host "`n== 汇总 ==" -ForegroundColor Cyan
Write-Host $summary
exit $(if ($failed.Count -eq 0) { 0 } else { 1 })
