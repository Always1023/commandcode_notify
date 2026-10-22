# Command Code 场景化提醒
# 由 mods/cmd-notify.ts 调用；也可单独手动运行测试
# 用法: notify.ps1 -Scenario done -Message "3 轮 · 12.3k tokens" -Project "my-app"
# 关闭: 在同目录建一个空的 notify.off 文件

param(
    [string]$Scenario = 'done',
    [string]$Message = '',
    [string]$Project = '',
    [switch]$DryRun,
    [switch]$Debug
)

$ErrorActionPreference = 'SilentlyContinue'
$root = Join-Path $env:USERPROFILE '.commandcode\hooks'

if (Test-Path (Join-Path $root 'notify.off')) { exit 0 }

# 场景表：emoji(颜色) / 标题 / 徽标底色 / 徽标图形 / 声音
$scenes = @{
    'done'        = @{ Emoji = '✅'; Title = '任务完成';   Color = '#22C55E'; Glyph = 'check'; Sound = 'ms-winsoundevent:Notification.Default' }
    'error'       = @{ Emoji = '❌'; Title = '运行出错';   Color = '#EF4444'; Glyph = 'cross'; Sound = 'ms-winsoundevent:Notification.Reminder' }
    'denied'      = @{ Emoji = '🚫'; Title = '权限被拒';   Color = '#F59E0B'; Glyph = 'bang';  Sound = 'ms-winsoundevent:Notification.IM' }
    'subagent'    = @{ Emoji = '🤖'; Title = '子代理结束'; Color = '#3B82F6'; Glyph = 'dot';   Sound = 'ms-winsoundevent:Notification.Mail' }
    'compact'     = @{ Emoji = '🗜️'; Title = '上下文压缩'; Color = '#A855F7'; Glyph = 'dot';   Sound = 'ms-winsoundevent:Notification.SMS' }
    'retry'       = @{ Emoji = '⏳'; Title = '接口重试';   Color = '#EAB308'; Glyph = 'dot';   Sound = 'ms-winsoundevent:Notification.Reminder' }
    'interrupted' = @{ Emoji = '⏹️'; Title = '已中断';     Color = '#6B7280'; Glyph = 'bars';  Sound = '' }
}

$s = $scenes[$Scenario]
if (-not $s) { $s = $scenes['done'] }

# 没有显式参数时，回落到读钩子 stdin 的 JSON
if (-not $Project -and [Console]::IsInputRedirected) {
    $raw = [Console]::In.ReadToEnd()
    if ($raw) {
        try {
            $o = $raw | ConvertFrom-Json
            if ($o.cwd) { $Project = Split-Path $o.cwd -Leaf }
        } catch {}
    }
}
if (-not $Project) { $Project = 'Command Code' }

# 可选：统一改标签 —— notify.config.json 里写 {"label":"我的项目"}
$cfgPath = Join-Path $root 'notify.config.json'
if (Test-Path $cfgPath) {
    try {
        $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.label) { $Project = [string]$cfg.label }
    } catch {}
}
if ($Project.Length -gt 26) { $Project = $Project.Substring(0, 25) + '…' }

$title = "$($s.Emoji) $($s.Title) · $Project"
$flat = ($Message -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' / '
$tail = if ($flat) { " :: $flat" } else { '' }

# 只拼标题不弹窗，用来验证
if ($DryRun) {
    try {
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Scenario] dryrun $title$tail" |
            Out-File -Append -Encoding utf8 (Join-Path $root 'notify.log')
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
    foreach ($line in ($Message -split "`r?`n")) {
        $ln = $line.Trim()
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
        $ni.ShowBalloonTip(6000, $title, $Message, [System.Windows.Forms.ToolTipIcon]::Info)
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
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Scenario] ok=$ok $title$tail" | Out-File -Append -Encoding utf8 $log
} catch {}

exit 0
