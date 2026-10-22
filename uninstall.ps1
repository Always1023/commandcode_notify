# cmd-notify 卸载脚本
# 用法: .\uninstall.ps1        移除 mod 与通知脚本，保留配置和徽标
#       .\uninstall.ps1 -All   连配置、徽标和日志一起删

param(
    [switch]$All
)

$ErrorActionPreference = 'Stop'

$cc = Join-Path $env:USERPROFILE '.commandcode'
$hooksDir = Join-Path $cc 'hooks'
$modsDir = Join-Path $cc 'mods'

$targets = @(
    (Join-Path $modsDir 'cmd-notify.ts'),
    (Join-Path $hooksDir 'notify.ps1')
)

if ($All) {
    $targets += (Join-Path $hooksDir 'notify.config.json')
    $targets += (Join-Path $hooksDir 'notify.log')
    $targets += (Join-Path $hooksDir 'notify.off')
}

foreach ($t in $targets) {
    if (Test-Path $t) {
        Remove-Item $t -Force
        Write-Output "已删除 $t"
    }
}

if ($All) {
    $badges = Join-Path $hooksDir 'badges'
    if (Test-Path $badges) {
        Remove-Item $badges -Recurse -Force
        Write-Output "已删除 $badges"
    }
}

Write-Output ''
Write-Output '重启 Command Code 生效。'
