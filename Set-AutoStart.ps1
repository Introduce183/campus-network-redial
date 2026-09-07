# 校园网拨号 - 开机自启设置
$ErrorActionPreference = 'Stop'

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$valueName = 'CampusNetworkRedial'
$scriptPath = Join-Path $PSScriptRoot 'Redial-UntilCampusReady.ps1'
$command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""

function Test-AutoStartEnabled {
    return $null -ne (Get-ItemProperty -Path $runKey -Name $valueName -ErrorAction SilentlyContinue)
}

while ($true) {
    Clear-Host
    Write-Host '================================================'
    Write-Host '    校园网拨号 - 开机自启设置'
    Write-Host '================================================'
    Write-Host ''
    $status = if (Test-AutoStartEnabled) { '已开启' } else { '未开启' }
    Write-Host "    当前状态：$status"
    Write-Host ''
    Write-Host '    [1] 开启开机自启（登录后自动运行拨号脚本）'
    Write-Host '    [2] 关闭开机自启'
    Write-Host '    [3] 退出'
    Write-Host ''
    $choice = Read-Host '请输入选项 (1/2/3)'

    if ($choice -eq '1') {
        Set-ItemProperty -Path $runKey -Name $valueName -Value $command
        Write-Host ''
        Write-Host '    [成功] 已开启开机自启，下次登录将自动运行拨号脚本。' -ForegroundColor Green
    }
    elseif ($choice -eq '2') {
        if (Test-AutoStartEnabled) {
            Remove-ItemProperty -Path $runKey -Name $valueName
            Write-Host ''
            Write-Host '    [成功] 已关闭开机自启。' -ForegroundColor Green
        }
        else {
            Write-Host ''
            Write-Host '    [提示] 当前未开启开机自启。' -ForegroundColor Yellow
        }
    }
    elseif ($choice -eq '3') {
        break
    }
    else {
        continue
    }

    Write-Host ''
    Read-Host '按回车返回菜单'
}
