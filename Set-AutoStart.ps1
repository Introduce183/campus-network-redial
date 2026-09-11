# 校园网拨号 - 开机自启设置
#
# 两个自启条目互相独立，可以分别开关，但它们用的是不同机制：
#   - 自动重拨脚本：HKCU Run 键（普通权限）
#   - 网络管理器：计划任务 + 最高权限
#     管理器要改电话簿里的 IpPrioritizeRemote、要加删默认路由和 /32 引导路由，
#     这些都需要管理员权限。Run 键没法让进程提权，用 Run 键启会每次登录弹一次 UAC，
#     所以只能用"以最高权限运行"的计划任务。
$ErrorActionPreference = 'Stop'

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$taskName = 'CampusNetworkManager'
$redialPath = Join-Path $PSScriptRoot 'Redial-UntilCampusReady.ps1'
$managerPath = Join-Path $PSScriptRoot 'Switch-NetworkPath.ps1'

# 必须在脚本作用域取好：函数内部的 $MyInvocation.MyCommand 是那个函数本身而不是脚本文件，
# 取 .Path 在 StrictMode 下会直接抛 "在此对象上找不到属性 Path"。
$script:SelfPath = $PSCommandPath

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-Elevated {
    Write-Host ''
    Write-Host '注册"最高权限计划任务"需要管理员权限，正在请求提权...' -ForegroundColor Yellow
    if (-not $script:SelfPath) {
        Write-Host '拿不到脚本自身路径，请用管理员身份手动运行本脚本。' -ForegroundColor Red
        return
    }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:SelfPath)
    Start-Sleep -Seconds 1
}

function Test-RedialEnabled {
    return $null -ne (Get-ItemProperty -Path $runKey -Name 'CampusNetworkRedial' -ErrorAction SilentlyContinue)
}

function Set-RedialEnabled {
    param([bool]$Enabled)
    if ($Enabled) {
        $command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$redialPath`""
        Set-ItemProperty -Path $runKey -Name 'CampusNetworkRedial' -Value $command
    }
    else {
        Remove-ItemProperty -Path $runKey -Name 'CampusNetworkRedial' -ErrorAction SilentlyContinue
    }
}

function Test-ManagerEnabled {
    return $null -ne (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)
}

function Set-ManagerEnabled {
    param([bool]$Enabled)
    if ($Enabled) {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $managerPath)
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force `
            -Description '校园网网络管理器：Wi-Fi 保底 + 拨号主用自动切换。需要管理员权限改电话簿与路由。' | Out-Null
    }
    else {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# 早期版本把管理器放在 Run 键里（无法提权、会弹 UAC），这里顺手清理掉。
function Remove-LegacyManagerRunKey {
    if (Get-ItemProperty -Path $runKey -Name 'CampusNetworkManager' -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $runKey -Name 'CampusNetworkManager' -ErrorAction SilentlyContinue
        return $true
    }
    return $false
}

if (-not (Test-Elevated)) {
    Restart-Elevated
    exit 0
}

$migrated = Remove-LegacyManagerRunKey

foreach ($path in @($redialPath, $managerPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "找不到脚本：$path" }
}

while ($true) {
    if ($migrated) {
        Clear-Host
        Write-Host '已清理旧版遗留：Run 键里的 CampusNetworkManager。'
        Write-Host '管理器改用计划任务运行，否则每次登录都要点一次 UAC。'
        $migrated = $false
        Start-Sleep -Seconds 2
    }

    Clear-Host
    Write-Host '================================================'
    Write-Host '    校园网拨号 - 开机自启设置'
    Write-Host '================================================'
    Write-Host ''
    Write-Host '    当前状态：'
    Write-Host ("      [{0}] 自动重拨脚本（HKCU Run）" -f $(if (Test-RedialEnabled) { '已开启' } else { '未开启' }))
    Write-Host ("      [{0}] 网络管理器（最高权限计划任务）" -f $(if (Test-ManagerEnabled) { '已开启' } else { '未开启' }))
    Write-Host ''
    Write-Host '    提示：两个不要同时开，它们会互相抢 rasdial；建议只开网络管理器。'
    Write-Host ''
    Write-Host '    [1] 开启 / 关闭  自动重拨脚本'
    Write-Host '    [2] 开启 / 关闭  网络管理器'
    Write-Host '    [3] 退出'
    Write-Host ''
    $choice = Read-Host '请输入选项 (1/2/3)'

    if ($choice -eq '3') { break }
    if ($choice -ne '1' -and $choice -ne '2') { continue }

    $isRedial = ($choice -eq '1')
    $wasEnabled = if ($isRedial) { Test-RedialEnabled } else { Test-ManagerEnabled }
    $label = if ($isRedial) { '自动重拨脚本' } else { '网络管理器' }

    try {
        if ($isRedial) { Set-RedialEnabled -Enabled (-not $wasEnabled) }
        else { Set-ManagerEnabled -Enabled (-not $wasEnabled) }
        Write-Host ''
        if ($wasEnabled) {
            Write-Host ("    [成功] 已关闭：{0}" -f $label) -ForegroundColor Green
        }
        else {
            Write-Host ("    [成功] 已开启：{0}" -f $label) -ForegroundColor Green
        }
    }
    catch {
        Write-Host ''
        Write-Host ("    [失败] {0}" -f $_.Exception.Message) -ForegroundColor Red
    }

    Write-Host ''
    Read-Host '按回车返回菜单'
}
