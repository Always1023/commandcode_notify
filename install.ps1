# cmd-notify 安装脚本
# 用法: .\install.ps1          安装并自检
#       .\install.ps1 -NoSelfTest   只安装，不跑自检

param(
    [switch]$NoSelfTest
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $MyInvocation.MyCommand.Path
$cc = Join-Path $env:USERPROFILE '.commandcode'
$modsDir = Join-Path $cc 'mods'
$hooksDir = Join-Path $cc 'hooks'

$modSrc = Join-Path $repo 'mods\cmd-notify.ts'
$hookSrc = Join-Path $repo 'hooks\notify.ps1'

foreach ($p in @($modSrc, $hookSrc)) {
    if (-not (Test-Path $p)) { throw "缺少文件: $p" }
}

New-Item -ItemType Directory -Force -Path $modsDir, $hooksDir | Out-Null

$modDst = Join-Path $modsDir 'cmd-notify.ts'
$hookDst = Join-Path $hooksDir 'notify.ps1'

Copy-Item $modSrc $modDst -Force
Copy-Item $hookSrc $hookDst -Force

Write-Output '已安装:'
Write-Output "  mod  -> $modDst"
Write-Output "  hook -> $hookDst"

if (-not (Get-Command commandcode -ErrorAction SilentlyContinue)) {
    Write-Warning '未找到 commandcode 命令。mod 会在 Command Code 可用后加载。'
}

if (-not $NoSelfTest) {
    try {
        & $hookDst -Scenario done -Project '安装自检' -DryRun
        $log = Join-Path $hooksDir 'notify.log'
        if (Test-Path $log) {
            Write-Output ''
            Write-Output ('自检: ' + (Get-Content $log -Tail 1))
        }
    } catch {
        Write-Warning "自检失败: $($_.Exception.Message)"
    }
}

Write-Output "`n下一步: 重启 Command Code（已开着的会话可以直接执行 /reload），然后执行 commandcode mods list 确认出现 cmd-notify。"
Write-Output 'mod 只在进程启动时加载一次，新建会话或新开标签页不会重新加载。'
