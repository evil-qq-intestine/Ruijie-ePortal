<#
.SYNOPSIS
    校园网 (锐捷 Ruijie ePortal) 自动认证 —— Windows 一键安装脚本

.DESCRIPTION
    1. 首次运行交互式询问: 门户地址 / 账号 / 密码 / 上网服务(教育网/电信/联通/移动)
    2. 自动写入认证脚本与配置, 并注册"计划任务"实现开机自动认证
    3. 之后每次开机自动认证; 掉线后每 1 分钟自动重连

.EXAMPLE
    # 交互式配置(推荐, 会自动请求管理员权限)
    powershell -ExecutionPolicy Bypass -File .\campus-portal-setup.ps1

.EXAMPLE
    # 全自动, 不询问
    powershell -ExecutionPolicy Bypass -File .\campus-portal-setup.ps1 -Yes -Username 学号 -Password 密码 -Service 教育网

.EXAMPLE
    # 卸载
    powershell -ExecutionPolicy Bypass -File .\campus-portal-setup.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$Username,
    [string]$Password,
    [string]$Service,
    [string]$Portal,
    [string]$CheckUrl,
    [int]$IntervalMinutes = 1,
    [switch]$Yes,
    [switch]$Uninstall,
    [switch]$KeepConfig
)

$ErrorActionPreference = 'Stop'
$WarningPreference     = 'SilentlyContinue'

# ------------------------------------------------------------------
# 默认值
# ------------------------------------------------------------------
$DefPortal     = '10.80.1.122'
$DefCheckUrl   = 'http://223.5.5.5/'
$DefService    = 'after-auth'
$BaseDir       = Join-Path $env:ProgramData 'CampusPortal'
$ConfPath      = Join-Path $BaseDir 'credentials.json'
$LoginScript   = Join-Path $BaseDir 'campus-portal-login.ps1'
$LogPath       = Join-Path $BaseDir 'login.log'
$TaskName      = 'CampusPortalLogin'
$UA            = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

function Write-Step  { param($m) Write-Host "[+ ] $m" -ForegroundColor Green }
function Write-Warn2 { param($m) Write-Host "[! ] $m" -ForegroundColor Yellow }
function Write-Err2  { param($m) Write-Host "[x ] $m" -ForegroundColor Red }
function Write-Hr    { Write-Host ('-' * 62) }

# ------------------------------------------------------------------
# 提权
# ------------------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Warn2 '需要管理员权限, 正在请求提权(会弹出 UAC 窗口, 请点"是")…'
    $exe = (Get-Process -Id $PID).Path
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $argList += "-$k" } }
        else { $argList += "-$k"; $argList += "`"$v`"" }
    }
    try {
        Start-Process -FilePath $exe -Verb RunAs -ArgumentList $argList
    } catch {
        Write-Err2 "提权失败: $($_.Exception.Message)"
        Write-Host  '请右键"以管理员身份运行" PowerShell 后重试。'
    }
    exit
}

# ------------------------------------------------------------------
# 卸载
# ------------------------------------------------------------------
if ($Uninstall) {
    Write-Hr; Write-Step '卸载校园网自动认证'
    $q = & schtasks.exe /Query /TN $TaskName 2>$null
    if ($LASTEXITCODE -eq 0) {
        & schtasks.exe /Delete /TN $TaskName /F | Out-Null
        Write-Step "已删除计划任务 $TaskName"
    } else {
        Write-Step "计划任务 $TaskName 不存在, 跳过"
    }
    if (Test-Path -LiteralPath $LoginScript) { Remove-Item -LiteralPath $LoginScript -Force }
    if (-not $KeepConfig -and (Test-Path -LiteralPath $ConfPath)) {
        Remove-Item -LiteralPath $ConfPath -Force
        Write-Step '已删除配置'
    }
    Write-Step '卸载完成'
    Write-Hr
    exit 0
}

# ------------------------------------------------------------------
# 读取已有配置作为默认值(重复运行可回车保留)
# ------------------------------------------------------------------
$Old = $null
if (Test-Path -LiteralPath $ConfPath) {
    try { $Old = Get-Content -LiteralPath $ConfPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $Old = $null }
}
function OldVal { param($name, $fallback) if ($Old -and $Old.PSObject.Properties.Name -contains $name -and $Old.$name) { $Old.$name } else { $fallback } }

# ------------------------------------------------------------------
# 服务名归一化
# ------------------------------------------------------------------
function Normalize-Service {
    param([string]$s)
    switch -Regex ($s) {
        '^(1|教育网|jy|edu|after-auth)?$'      { return 'after-auth' }
        '^(2|电信|电信服务|dx)$'               { return 'dx' }
        '^(3|联通|联通服务|lt)$'               { return 'lt' }
        '^(4|移动|移动服务|yd)$'               { return 'yd' }
        default                                { return $s }
    }
}
function Service-Label {
    param([string]$s)
    switch ($s) {
        'after-auth' { return '教育网' }
        'dx'         { return '电信服务' }
        'lt'         { return '联通服务' }
        'yd'         { return '移动服务' }
        default      { return $s }
    }
}

function Read-Default {
    param([string]$Prompt, [string]$Default, [switch]$Required)
    while ($true) {
        if ($Default) { $ans = Read-Host "$Prompt [$Default]" } else { $ans = Read-Host $Prompt }
        if ([string]::IsNullOrWhiteSpace($ans)) { $ans = $Default }
        if ([string]::IsNullOrWhiteSpace($ans) -and $Required) {
            Write-Warn2 '该项不能为空, 请重新输入'; continue
        }
        return $ans
    }
}

# ------------------------------------------------------------------
# 交互式收集配置
# ------------------------------------------------------------------
Write-Hr
Write-Host '校园网自动认证 · 首次配置 (Windows)' -ForegroundColor Cyan
Write-Hr

if (-not $Portal)   { $Portal   = if ($Yes) { OldVal 'PortalIp' $DefPortal }   else { Read-Default '认证门户 IP' (OldVal 'PortalIp' $DefPortal) -Required } }
if (-not $CheckUrl) { $CheckUrl = if ($Yes) { OldVal 'CheckUrl' $DefCheckUrl } else { Read-Default '认证检测地址(未认证时会被劫持的网址)' (OldVal 'CheckUrl' $DefCheckUrl) -Required } }
$Portal = ($Portal -replace '^https?://', '') -replace '/.*$', ''

if (-not $Username) {
    if ($Yes) {
        $Username = OldVal 'Username' ''
        if (-not $Username) { Write-Err2 '-Yes 模式下必须用 -Username 指定账号'; exit 1 }
    } else {
        $Username = Read-Default '校园网账号' (OldVal 'Username' '') -Required
    }
}

$oldPwd = OldVal 'Password' ''
if (-not $Password) {
    if ($Yes) {
        $Password = $oldPwd
        if (-not $Password) { Write-Err2 '-Yes 模式下必须用 -Password 指定密码'; exit 1 }
    } else {
        if ($oldPwd) {
            $sec = Read-Host '校园网密码 [直接回车保留原密码]' -AsSecureString
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
            if ([string]::IsNullOrEmpty($plain)) { $Password = $oldPwd } else { $Password = $plain }
        } else {
            while ($true) {
                $sec = Read-Host '校园网密码(输入时不显示)' -AsSecureString
                $p1  = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
                if ([string]::IsNullOrEmpty($p1)) { Write-Warn2 '密码不能为空'; continue }
                $sec2 = Read-Host '再输入一次确认' -AsSecureString
                $p2   = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec2))
                if ($p1 -eq $p2) { $Password = $p1; break }
                Write-Warn2 '两次输入不一致, 请重新输入'
            }
        }
    }
}

if (-not $Service) {
    if ($Yes) {
        $Service = OldVal 'Service' $DefService
    } else {
        Write-Host ''
        Write-Host '请选择上网服务类型:'
        Write-Host '  1) 教育网   (after-auth)   <- 默认, 校园网内网/教育网出口'
        Write-Host '  2) 电信服务 (dx)'
        Write-Host '  3) 联通服务 (lt)'
        Write-Host '  4) 移动服务 (yd)'
        Write-Host '  5) 其他(手动输入)'
        $ans = Read-Host '选择 [1]'
        if ([string]::IsNullOrWhiteSpace($ans)) { $ans = '1' }
        if ($ans -eq '5') {
            $Service = Read-Default '请输入服务标识' $DefService -Required
        } else {
            $Service = Normalize-Service $ans
        }
    }
}
$Service = Normalize-Service $Service

# ------------------------------------------------------------------
# 确认
# ------------------------------------------------------------------
Write-Hr
Write-Host '即将安装以下配置:'
Write-Host ("  {0,-10} {1}" -f '门户地址',  "http://$Portal")
Write-Host ("  {0,-10} {1}" -f '检测地址',  $CheckUrl)
Write-Host ("  {0,-10} {1}" -f '账号',      $Username)
Write-Host ("  {0,-10} {1}" -f '密码',      ('*' * $Password.Length))
Write-Host ("  {0,-10} {1}" -f '上网服务',  "$(Service-Label $Service)  [$Service]")
Write-Host ("  {0,-10} {1}" -f '检测间隔',  "$IntervalMinutes 分钟")
Write-Host ("  {0,-10} {1}" -f '开机自启',  '是 (计划任务)')
Write-Host ("  {0,-10} {1}" -f '安装位置',  $BaseDir)
Write-Hr
if (-not $Yes) {
    $ok = Read-Host '确认安装? [Y/n]'
    if ($ok -match '^(n|N|no|NO)$') { Write-Step '已取消'; exit 0 }
}

# ------------------------------------------------------------------
# 建目录
# ------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $BaseDir)) { New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null }

# ------------------------------------------------------------------
# 导出认证脚本本体
# ------------------------------------------------------------------
Write-Step "写入认证脚本 $LoginScript"

$LoginBody = @'
# 校园网 (锐捷 ePortal) 自动认证 —— 由计划任务 CampusPortalLogin 定时调用
# 也可手动执行:  powershell -ExecutionPolicy Bypass -File campus-portal-login.ps1 [-Force]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
$WarningPreference     = 'SilentlyContinue'

$BaseDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfPath  = Join-Path $BaseDir 'credentials.json'
$LogPath   = Join-Path $BaseDir 'login.log'
$UA        = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Log {
    param([string]$msg)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try {
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 1MB) {
            $tail = Get-Content -LiteralPath $LogPath -Tail 200 -ErrorAction SilentlyContinue
            [System.IO.File]::WriteAllLines($LogPath, $tail, $Utf8NoBom)
        }
        [System.IO.File]::AppendAllText($LogPath, $line + "`r`n", $Utf8NoBom)
    } catch { }
    Write-Host $line
}

function Invoke-Http {
    param(
        [string]$Url,
        [string]$Method = 'GET',
        [string]$Body = $null,
        [string]$ContentType = $null,
        [int]$TimeoutSec = 10,
        [switch]$NoRedirect
    )
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method            = $Method
    $req.Timeout           = $TimeoutSec * 1000
    $req.ReadWriteTimeout  = $TimeoutSec * 1000
    $req.AllowAutoRedirect = -not $NoRedirect
    $req.UserAgent         = $UA
    $req.Proxy             = $null      # 不继承系统代理, 避免门户请求被代理软件截走
    if ($ContentType) { $req.ContentType = $ContentType }
    if ($Body) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
    }
    $resp = $null
    try {
        $resp = $req.GetResponse()
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) { $resp = $_.Exception.Response } else { throw }
    }
    $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
    $text = $reader.ReadToEnd()
    $reader.Close()
    $out = [pscustomobject]@{
        StatusCode = [int]$resp.StatusCode
        Location   = [string]$resp.Headers['Location']
        Body       = $text
    }
    $resp.Close()
    return $out
}

if (-not (Test-Path -LiteralPath $ConfPath)) { Write-Log "缺少配置文件 $ConfPath"; exit 1 }
$cfg = Get-Content -LiteralPath $ConfPath -Raw -Encoding UTF8 | ConvertFrom-Json

$PortalIp = if ($cfg.PortalIp) { $cfg.PortalIp } else { '10.80.1.122' }
$CheckUrl = if ($cfg.CheckUrl) { $cfg.CheckUrl } else { 'http://223.5.5.5/' }
$Service  = if ($cfg.Service)  { $cfg.Service }  else { 'after-auth' }

# ---------- 1. 判断是否需要认证 ----------
$body = ''
try {
    $r = Invoke-Http -Url $CheckUrl -TimeoutSec 8
    $body = $r.Body
} catch {
    Write-Log "请求检测地址失败: $($_.Exception.Message)"
}

$intercepted = $false
if ($body -and ($body -match 'eportal/index\.jsp|eportal/InterFace\.do')) { $intercepted = $true }

if (-not $intercepted -and -not $Force) {
    Write-Log '网络已认证，无需登录'
    exit 0
}
if ($Force) { Write-Log '强制认证模式' }

# ---------- 2. 取出门户地址与 queryString ----------
$purl = ''
if ($body -and ($body -match "location\.href='([^']+)'")) { $purl = $Matches[1] }

if (-not $purl) {
    try {
        $r2 = Invoke-Http -Url $CheckUrl -TimeoutSec 8 -NoRedirect
        if ($r2.Location -and ($r2.Location -match 'index\.jsp')) { $purl = $r2.Location }
    } catch { }
}

if (-not $purl) {
    if (-not $intercepted) { Write-Log '当前未被门户拦截，网络已认证，无需操作'; exit 0 }
    Write-Log '无法取得门户地址，放弃本次认证'
    exit 2
}
$qs = ''
if ($purl -match '\?(.*)$') { $qs = $Matches[1] }
Write-Log '检测到门户拦截，开始认证…'
Write-Log "门户地址: $purl"

# ---------- 3. 提交认证 ----------
# 注意: 这里刻意采用「换行分隔(不写逗号) + [string]::Join」的写法。
# 实测在部分 PowerShell 解析场景下, 多行 @() 内用逗号分隔再直接接 -join,
# 会把整个数组当成单个元素并用 $OFS(空格) 拼接输出,
# 结果表单分隔符全变成空格 -> 门户会判定参数非法而拒绝认证。
$sep = [char]38
$parts = @(
    'userId='      + [Uri]::EscapeDataString([string]$cfg.Username)
    'password='    + [Uri]::EscapeDataString([string]$cfg.Password)
    'service='     + [Uri]::EscapeDataString($Service)
    'queryString=' + [Uri]::EscapeDataString($qs)
    'operatorPwd='
    'operatorUserId='
    'validcode='
    'passwordEncrypt=false'
)
$form = [string]::Join($sep, $parts)

$apiUrl = "http://$PortalIp/eportal/InterFace.do?method=login"
try {
    $resp = Invoke-Http -Url $apiUrl -Method 'POST' -Body $form `
                        -ContentType 'application/x-www-form-urlencoded; charset=UTF-8' `
                        -TimeoutSec 15
} catch {
    Write-Log "认证请求失败: $($_.Exception.Message)"
    exit 3
}

$text = [string]$resp.Body
if ($text -match '"result"\s*:\s*"success"') {
    $m = ''
    if ($text -match '"message"\s*:\s*"([^"]*)"') { $m = $Matches[1] }
    if ($m) { Write-Log "认证成功（服务器提示: $m）" } else { Write-Log '认证成功' }
    exit 0
} elseif ($text -match '已经在线|已在线|重复登录') {
    Write-Log '账号已在线'
    exit 0
} else {
    Write-Log "认证失败，服务器返回: $text"
    exit 3
}
'@

# 注意: 必须带 UTF-8 BOM 写盘。Windows PowerShell 5.1 会把「无 BOM 的 .ps1」
# 当作 ANSI(中文系统=GBK) 解析, 中文会乱码并报 "缺少字符串终止符" 之类的语法错误。
$Utf8Bom   = New-Object System.Text.UTF8Encoding($true)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($LoginScript, $LoginBody, $Utf8Bom)

# 语法自检
$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($LoginScript, [ref]$null, [ref]$errs)
if ($errs -and $errs.Count -gt 0) {
    Write-Err2 "认证脚本语法错误: $($errs[0].Message)"
    exit 1
}

# ------------------------------------------------------------------
# 写配置(含明文密码, ACL 收紧到 SYSTEM + Administrators)
# ------------------------------------------------------------------
Write-Step "写入配置 $ConfPath"
$confObj = [ordered]@{
    Username  = $Username
    Password  = $Password
    Service   = $Service
    PortalIp  = $Portal
    CheckUrl  = $CheckUrl
}
$json = $confObj | ConvertTo-Json -Depth 3
[System.IO.File]::WriteAllText($ConfPath, $json, $Utf8NoBom)

& icacls.exe $ConfPath /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
& icacls.exe $BaseDir  /grant '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null

# ------------------------------------------------------------------
# 注册计划任务: 每 N 分钟跑一次(含开机后自动运行)
# ------------------------------------------------------------------
Write-Step '注册计划任务(开机自动运行 + 每分钟检测掉线)'
$tr = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$LoginScript`""
& schtasks.exe /Delete /TN $TaskName /F 2>$null | Out-Null
& schtasks.exe /Create /TN $TaskName /TR $tr /SC MINUTE /MO $IntervalMinutes /RU SYSTEM /RL HIGHEST /F | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Warn2 'schtasks 创建失败, 尝试用计划任务模块…'
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$LoginScript`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
    $trig2   = New-ScheduledTaskTrigger -AtStartup
    $set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($trig2, $trigger) -Settings $set -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
}

# ------------------------------------------------------------------
# 立即试跑一次
# ------------------------------------------------------------------
Write-Step '立即执行一次认证测试…'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $LoginScript
switch ($LASTEXITCODE) {
    0       { Write-Step '认证测试: 通过' }
    2       { Write-Warn2 '认证测试: 未取到门户地址(可能当前无网或已认证)' }
    3       { Write-Warn2 '认证测试: 服务器拒绝了认证, 请检查账号/密码/服务类型' }
    default { Write-Warn2 "认证测试: 异常退出码 $LASTEXITCODE" }
}

# ------------------------------------------------------------------
# 完成
# ------------------------------------------------------------------
Write-Hr
Write-Step '安装完成'
Write-Hr
Write-Host ("  {0,-10} {1}" -f '配置文件',   "$ConfPath  (ACL 仅 SYSTEM/管理员)")
Write-Host ("  {0,-10} {1}" -f '认证脚本',   $LoginScript)
Write-Host ("  {0,-10} {1}" -f '运行日志',   $LogPath)
Write-Host ("  {0,-10} {1}" -f '计划任务',   "$TaskName  (每 $IntervalMinutes 分钟, 开机自动运行)")
Write-Host ''
Write-Host '常用命令 (需管理员 PowerShell):'
Write-Host "  立即认证一次 : schtasks /Run /TN $TaskName"
Write-Host "  强制重新认证 : powershell -ExecutionPolicy Bypass -File `"$LoginScript`" -Force"
Write-Host "  查看日志     : Get-Content `"$LogPath`" -Tail 20 -Wait"
Write-Host "  修改账号密码 : powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`""
Write-Host "  卸载         : powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Uninstall"
Write-Hr
