# Command Code 场景化提醒
# 由 mods/cmd-notify.ts 调用；也可手动测试
# 用法: notify.ps1 -Scenario done -Project "my-app" -Data64 "<base64 的 JSON>"
# 语言: -Lang zh|en|auto，默认 auto（跟随系统界面语言）
# 关闭: 在同目录建一个空的 notify.off 文件

param(
    [string]$Scenario = 'done',
    [string]$Project = '',
    [string]$Data64 = '',
    [string]$Message = '',
    [string]$Lang = '',
    [switch]$DryRun,
    [switch]$Debug
)

$ErrorActionPreference = 'SilentlyContinue'
$root = Join-Path $env:USERPROFILE '.commandcode\hooks'

if (Test-Path (Join-Path $root 'notify.off')) { exit 0 }

# ---- 配置 ----
$cfg = $null
$cfgPath = Join-Path $root 'notify.config.json'
if (Test-Path $cfgPath) {
    try { $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}

# ---- 语言：-Lang > 配置 lang > 系统界面语言 ----
$langName = $Lang
if (-not $langName -and $cfg -and $cfg.lang) { $langName = [string]$cfg.lang }
if (-not $langName -or $langName -eq 'auto') {
    try { $langName = [System.Globalization.CultureInfo]::CurrentUICulture.Name } catch {}
}
if (-not $langName) {
    try { $langName = [System.Globalization.CultureInfo]::InstalledUICulture.Name } catch {}
}
if (-not $langName) { $langName = $env:LANG }
$isZh = "$langName" -like 'zh*'
# 日志里只打基础语言，避免出现 [done/zh-CN] 与 [done/en] 混着看
$langTag = if ($isZh) { 'zh' } else { 'en' }

function Loc {
    param([string]$Zh, [string]$En)
    if ($isZh) { return $Zh }
    return $En
}

function Fmt-Tokens {
    param($n)
    $v = 0.0
    if (-not [double]::TryParse([string]$n, [ref]$v)) { return '' }
    if ($v -le 0) { return '' }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($v -ge 1000000) { return (($v / 1000000).ToString('0.#', $inv) + 'M tokens') }
    if ($v -ge 1000) { return (($v / 1000).ToString('0.#', $inv) + 'k tokens') }
    return ([int]$v).ToString($inv) + ' tokens'
}

# 日志用单次追加，避免多条通知并发写时把行写花。
# 首次写入带 BOM：Windows PowerShell 5.1 的 Get-Content 靠 BOM 认 UTF-8。
function Write-Log {
    param([string]$Path, [string]$Line)
    $text = $Line + "`r`n"
    if (Test-Path $Path) {
        [System.IO.File]::AppendAllText($Path, $text, (New-Object System.Text.UTF8Encoding $false))
    } else {
        [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding $true))
    }
}

# ---- 场景表 ----
$scenes = @{
    'done'        = @{ Emoji = '✅'; Zh = '任务完成'; En = 'Task finished';       Color = '#22C55E'; Glyph = 'check'; Sound = 'ms-winsoundevent:Notification.Default' }
    'error'       = @{ Emoji = '❌'; Zh = '运行出错'; En = 'Run failed';          Color = '#EF4444'; Glyph = 'cross'; Sound = 'ms-winsoundevent:Notification.Reminder' }
    'denied'      = @{ Emoji = '🚫'; Zh = '权限被拒'; En = 'Permission denied';   Color = '#F59E0B'; Glyph = 'bang';  Sound = 'ms-winsoundevent:Notification.IM' }
    'subagent'    = @{ Emoji = '🤖'; Zh = '子代理结束'; En = 'Subagent finished'; Color = '#3B82F6'; Glyph = 'dot';   Sound = 'ms-winsoundevent:Notification.Mail' }
    'compact'     = @{ Emoji = '🗜️'; Zh = '上下文压缩'; En = 'Context compacted'; Color = '#A855F7'; Glyph = 'dot';   Sound = 'ms-winsoundevent:Notification.SMS' }
    'retry'       = @{ Emoji = '⏳'; Zh = '接口重试'; En = 'API retry';           Color = '#EAB308'; Glyph = 'dot';   Sound = 'ms-winsoundevent:Notification.Reminder' }
    'interrupted' = @{ Emoji = '⏹️'; Zh = '已中断'; En = 'Interrupted';           Color = '#6B7280'; Glyph = 'bars';  Sound = '' }
}

$s = $scenes[$Scenario]
if (-not $s) { $s = $scenes['done'] }

# ---- 读取 mod 传来的结构化数据 ----
$data = $null
if ($Data64) {
    try {
        $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Data64))
        $data = $json | ConvertFrom-Json
    } catch {}
}

# 没有显式 Project 时，回落到读钩子 stdin 的 JSON
if (-not $Project -and [Console]::IsInputRedirected) {
    $raw = [Console]::In.ReadToEnd()
    if ($raw) {
        try {
            $o = $raw | ConvertFrom-Json
            if ($o.cwd) { $Project = Split-Path $o.cwd -Leaf }
        } catch {}
    }
}

if ($cfg -and $cfg.label) { $Project = [string]$cfg.label }
if (-not $Project) { $Project = 'Command Code' }
if ($Project.Length -gt 26) { $Project = $Project.Substring(0, 25) + '…' }

# ---- 拼正文 ----
$tokens = if ($data) { Fmt-Tokens $data.tokens } else { '' }

$meta = @()
if ($data -and $data.turns) {
    $t = [int]$data.turns
    $turnText = if ($isZh) { "$t 轮" } elseif ($t -eq 1) { '1 turn' } else { "$t turns" }
    $meta += $turnText
}
if ($tokens) { $meta += $tokens }
$metaText = if ($meta.Count -gt 0) { $meta -join ' · ' } else { '' }

$lines = @()
if ($Message) {
    $lines = @($Message -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
} else {
    switch ($Scenario) {
        'done' {
            if ($metaText) { $lines += $metaText }
            if ($data -and $data.snippet) { $lines += [string]$data.snippet }
        }
        'interrupted' {
            if ($metaText) { $lines += $metaText }
            $lines += (Loc '已取消这次运行' 'Run cancelled')
        }
        'error' {
            if ($data -and $data.snippet) { $lines += [string]$data.snippet }
            else { $lines += (Loc '运行以错误结束' 'Run ended with an error') }
        }
        'denied' {
            if ($data -and $data.tool) {
                $lines += (Loc "工具 $($data.tool) 被拒绝执行" "Tool $($data.tool) was denied")
            } else {
                $lines += (Loc '有工具调用被拒绝执行' 'A tool call was denied')
            }
        }
        'subagent' {
            $type = if ($data -and $data.subagentType) { [string]$data.subagentType } else { Loc '子代理' 'Subagent' }
            $lines += (Loc "$type 已结束" "$type finished")
            if ($tokens) { $lines += $tokens }
        }
        'compact' {
            $saved = if ($data) { Fmt-Tokens $data.saved } else { '' }
            if ($saved) { $lines += (Loc "省下 $saved" "Saved $saved") }
            else { $lines += (Loc '上下文已压缩' 'Context compacted') }
        }
        'retry' {
            $r = @()
            if ($data -and $data.attempt) {
                $a = [int]$data.attempt
                $r += (Loc "第 $a 次" "attempt $a")
            }
            if ($data -and $data.delay) {
                $sec = [math]::Round([double]$data.delay / 1000)
                $r += (Loc "$sec 秒后重试" "retry in ${sec}s")
            }
            if ($r.Count -gt 0) { $lines += ($r -join ' · ') }
            if ($data -and $data.detail) { $lines += [string]$data.detail }
        }
    }
}

$titleText = if ($isZh) { $s.Zh } else { $s.En }
$title = "$($s.Emoji) $titleText · $Project"
$flat = ($lines -join ' / ')
$tail = if ($flat) { " :: $flat" } else { '' }

# 只拼标题不弹窗，用来验证
if ($DryRun) {
    try {
        $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Scenario/$langTag] dryrun $title$tail"
        Write-Log (Join-Path $root 'notify.log') $line
    } catch {}
    exit 0
}

# ---- 生成彩色徽标（缓存） ----
function New-Badge {
    param([string]$Color, [string]$Glyph, [string]$Path)
    Add-Type -AssemblyName System.Drawing
    $size = 96
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $c = [System.Drawing.ColorTranslator]::FromHtml($Color)
    $brush = New-Object System.Drawing.SolidBrush $c
    $r = 20
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $gp.AddArc(0, 0, $r, $r, 180, 90)
    $gp.AddArc(($size - 1 - $r), 0, $r, $r, 270, 90)
    $gp.AddArc(($size - 1 - $r), ($size - 1 - $r), $r, $r, 0, 90)
    $gp.AddArc(0, ($size - 1 - $r), $r, $r, 90, 90)
    $gp.CloseFigure()
    $g.FillPath($brush, $gp)

    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 9
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $wb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)

    switch ($Glyph) {
        'check' {
            $pts = [System.Drawing.PointF[]]@(
                [System.Drawing.PointF]::new(26, 50),
                [System.Drawing.PointF]::new(42, 66),
                [System.Drawing.PointF]::new(70, 34)
            )
            $g.DrawLines($pen, $pts)
        }
        'cross' {
            $g.DrawLine($pen, 30, 30, 66, 66)
            $g.DrawLine($pen, 66, 30, 30, 66)
        }
        'bang' {
            $g.FillRectangle($wb, 42, 24, 12, 34)
            $g.FillEllipse($wb, 40, 66, 16, 16)
        }
        'bars' {
            $g.FillRectangle($wb, 34, 28, 12, 40)
            $g.FillRectangle($wb, 54, 28, 12, 40)
        }
        default {
            $g.FillEllipse($wb, 32, 32, 32, 32)
        }
    }

    $g.Dispose()
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

$badgeDir = Join-Path $root 'badges'
if (-not (Test-Path $badgeDir)) { New-Item -ItemType Directory -Path $badgeDir -Force | Out-Null }
$badge = Join-Path $badgeDir "$Scenario.png"
if (-not (Test-Path $badge)) {
    try { New-Badge -Color $s.Color -Glyph $s.Glyph -Path $badge } catch { $badge = $null }
}
if ($badge -and -not (Test-Path $badge)) { $badge = $null }

$ok = $false
try {
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime]

    $t = [System.Security.SecurityElement]::Escape($title)
    $img = ''
    if ($badge) {
        $uri = 'file:///' + ($badge -replace '\\', '/')
        $img = "<image placement=`"appLogoOverride`" hint-crop=`"circle`" src=`"$uri`"/>"
    }
    $audio = ''
    if ($s.Sound) { $audio = "<audio src=`"$($s.Sound)`"/>" }

    $body = "<text>$t</text>"
    foreach ($line in $lines) {
        $ln = ([string]$line).Trim()
        if ($ln) { $body += "<text>$([System.Security.SecurityElement]::Escape($ln))</text>" }
    }

    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml("<toast><visual><binding template=`"ToastGeneric`">$body$img</binding></visual>$audio</toast>")
    $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe').Show($toast)
    $ok = $true
} catch {}

if (-not $ok) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $ni = New-Object System.Windows.Forms.NotifyIcon
        if ($badge) {
            $ni.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon((Join-Path $env:SystemRoot 'System32\shell32.dll'))
        } else {
            $ni.Icon = [System.Drawing.SystemIcons]::Information
        }
        $ni.Visible = $true
        $ni.ShowBalloonTip(6000, $title, ($lines -join "`n"), [System.Windows.Forms.ToolTipIcon]::Info)
        Start-Sleep -Seconds 6
        $ni.Dispose()
        $ok = $true
    } catch {}
}

if (-not $ok) {
    try { [console]::beep(880, 200) } catch {}
}

# 轻量日志，方便排查（超过 200KB 自动清空）
$log = Join-Path $root 'notify.log'
try {
    if ((Test-Path $log) -and ((Get-Item $log).Length -gt 200KB)) { Remove-Item $log -Force }
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Scenario/$langTag] ok=$ok $title$tail"
    Write-Log $log $line
} catch {}

exit 0
