<#
.SYNOPSIS
校园网网络管理器 —— WinForms 图形界面（两个模式：正常重拨 / 游戏模式）。

.DESCRIPTION
这一层**只做界面和调度**，一行业务逻辑都不重复实现：判定、停放开关、/32 引导、双断言、
退避、健康检查判据全都留在旁边那几个脚本里（那些是一整轮实机测出来的结论）。

两个大模式（互斥，不能同时跑 —— 两边都会抢 rasdial）：

  1. **正常重拨模式** = `Redial-UntilCampusReady.ps1`
       重新拨号，直到三轮探测确认拿到好出口；运行方式三选一（普通重拨 / 只测当前出口 / 高速模式）。
       它的输出会实时显示在下面日志区（同一次运行的完整输出另外留一份在 logs\redial-*.out.txt）。

  2. **游戏模式** = `Switch-NetworkPath.ps1`（常驻管理器）
       把拨号停放到 Wi-Fi 旁边、确认好出口后再提为主用，出口变坏立刻退回 Wi-Fi。
       硬前提是**先连上热点**，没连上时开关会置灰（其它功能不受影响）。

共用的几件小事：实时状态面板、恢复拨号优先、测一轮双出口。

几个刻意的设计：
  - **停管理器走"优雅退出"**（写 logs\stop.req 让它自己退），不是直接杀进程 —— 直接杀会跳过它的还原逻辑，
    电话簿会留在停放态、晋升残留路由也会留下。
  - **停重拨模式是真杀进程**（重拨脚本没有需要收尾的资源），但杀完会检查拨号是否还连着，没连就补拨一次。
  - **定时刷新只读文件**，不每 2 秒 spawn 一个 powershell；要实时值时才主动跑一次 -StatusJson。
  - 子进程一律无窗口，避免 GUI 旁边闪控制台。
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# 给这个进程一个**自己的任务栏身份**。
# 界面是跑在 powershell.exe 里的，默认会继承 PowerShell 的 AppUserModelID ——
# 任务栏/托盘就会按 PowerShell 来归类（实测：系统里连一条属于本程序的托盘图标记录都没有），
# 按钮图标也可能跟着用宿主的。设了自己的 ID 之后，Windows 按窗口自己的图标来画。
# 必须在创建任何窗口之前调用。
try {
    Add-Type -Namespace Win32 -Name AppId -MemberDefinition @'
[DllImport("shell32.dll", SetLastError = true)]
public static extern int SetCurrentProcessExplicitAppUserModelID(
    [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string AppID);
'@ -ErrorAction Stop
    $hr = [Win32.AppId]::SetCurrentProcessExplicitAppUserModelID('Introduce183.CampusNetworkRedial')
    $script:AppIdResult = $hr      # 0 = S_OK；非 0 说明没设上，会写进 logs\ui.log 方便排查
}
catch {
    # 这里不能用 Write-UiError：它定义在下面的路径段之后，此刻还不存在（纯可选功能，静默即可）
}

# ---------------------------------------------------------------- 路径

$script:Root = $PSScriptRoot
$script:EnginePath = Join-Path $script:Root 'Switch-NetworkPath.ps1'
$script:RedialPath = Join-Path $script:Root 'Redial-UntilCampusReady.ps1'
$script:AutoStartPath = Join-Path $script:Root 'Set-AutoStart.ps1'
$script:BothExitsPath = Join-Path $script:Root 'Test-BothExits.ps1'
$script:LogDir = Join-Path $script:Root 'logs'
$script:StatusFile = Join-Path $script:LogDir 'status.json'
$script:StopFile = Join-Path $script:LogDir 'stop.req'

foreach ($p in @($script:EnginePath, $script:RedialPath, $script:AutoStartPath, $script:BothExitsPath)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "找不到脚本：$p" }
}
if (-not (Test-Path -LiteralPath $script:LogDir)) {
    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
}

# 子进程的输出编码坑：powershell 在**重定向**（不是控制台）时按系统的 ANSI 码页写 stdout，
# 不是 UTF-8。实测子进程写出的中文用 UTF-8 去读会变成乱码，按 ANSI 码页读才对
# （本机 = 936/GBK）。所以凡是读子进程输出的地方都显式用这个编码，不靠默认值。
$script:ChildEncoding = [Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)

function Write-UiError {
    # WinForms 会把事件处理器里的异常吞掉（或弹一个模态框），界面看着还在、其实那一步没生效。
    # 所以凡是可能抛的地方都往 logs\ui-error.log 留一条 —— 不然只能靠猜。
    param([string]$Where, $Err)
    $msg = ''
    $stack = ''
    try {
        if ($Err -is [System.Management.Automation.ErrorRecord]) {
            $msg = $Err.Exception.Message
            $stack = [string]$Err.ScriptStackTrace
        }
        elseif ($Err -is [Exception]) { $msg = $Err.Message; $stack = [string]$Err.StackTrace }
        else { $msg = [string]$Err }
    }
    catch { $msg = '(取异常信息都失败了)' }
    try {
        [IO.File]::AppendAllText((Join-Path $script:LogDir 'ui-error.log'),
            ('{0} [{1}] {2}{3}{4}{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Where, $msg, [Environment]::NewLine, $stack),
            [Text.UTF8Encoding]::new($false))
    }
    catch { }
}

# 定时器/按钮回调里的异常默认会弹模态框并顶掉窗口标题，捕获模式改成自己处理 + 落盘。
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    Write-UiError -Where 'ThreadException' -Err $e.Exception
})

# ---------------------------------------------------------------- 通用

function Invoke-Hidden {
    # 同步跑一个 powershell 子进程：无窗口，拿回 stdout / stderr 和**真正的退出码**。
    #
    # 刻意用 .NET 的 Process 而不是 Start-Process：`Start-Process -PassThru` 返回的对象
    # 读 .ExitCode 实测是空的（只有 `-Wait -PassThru` 才有），而这里正需要退出码来判断成败。
    param([string[]]$Target, [int]$TimeoutSeconds = 90, [switch]$KeepStderr)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File') + $Target |
        ForEach-Object { '"' + $_ + '"' }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.StandardOutputEncoding = $script:ChildEncoding
    $psi.StandardErrorEncoding = $script:ChildEncoding

    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $exited = $proc.WaitForExit($TimeoutSeconds * 1000)
    if (-not $exited) { try { $proc.Kill() } catch { } }

    $output = ''
    $errText = ''
    try { $output = $outTask.Result } catch { }
    try { $errText = $errTask.Result } catch { }
    if ($KeepStderr) { $output += $errText }
    $code = if ($proc.HasExited) { $proc.ExitCode } else { $null }
    $proc.Dispose()

    return [pscustomobject]@{ ExitCode = $code; Output = $output; Error = $errText; Exited = $exited }
}

function Test-ManagerRunning {
    # 单实例互斥体是管理器的"我在跑"标志。GUI 只是**问一下**有没有被占，自己拿到就立刻释放。
    $m = $null
    $got = $false
    try {
        $m = [System.Threading.Mutex]::new($false, 'Local\CampusNetworkPath')
        try {
            $got = $m.WaitOne(0)
        }
        catch [System.Threading.AbandonedMutexException] {
            # 上一个实例被硬杀过：互斥体被"遗弃"→ 拿的时候抛异常，但确实没有实例在跑。
            # 这里当成"拿到了"（好让 finally 把它释放掉，把遗弃状态清干净）。
            $got = $true
        }
        return (-not $got)
    }
    catch { return $false }
    finally {
        if ($m -and $got) { try { $m.ReleaseMutex() } catch { } }
        if ($m) { try { $m.Dispose() } catch { } }
    }
}

function Get-StatusObject {
    # -Fresh：真跑一次 -StatusJson（要起一个进程，只在需要实时值时才用）。
    # 否则读管理器写的 logs\status.json —— 纯文件读。注意这个文件是引擎用 **UTF-8** 写的，
    # 和"子进程重定向输出用 ANSI 码页"是两回事，别混。
    param([switch]$Fresh)

    if (-not $Fresh) {
        if (-not (Test-Path -LiteralPath $script:StatusFile)) { return $null }
        try { return ([IO.File]::ReadAllText($script:StatusFile) | ConvertFrom-Json) } catch { return $null }
    }
    $r = Invoke-Hidden -Target @($script:EnginePath, '-StatusJson') -TimeoutSeconds 60
    try { return ($r.Output | ConvertFrom-Json) } catch { return $null }
}

# ---------------------------------------------------------------- 游戏模式

function Start-GameMode {
    if (Test-ManagerRunning) { return 'already' }

    # 硬前提：热点必须先连上。这正是引擎自己的启动守卫，这里只是提前告诉用户为什么。
    $status = Get-StatusObject -Fresh
    if (-not $status -or -not $status.wifiAlive) { return 'no-wifi' }

    if (Test-Path -LiteralPath $script:StopFile) {
        Remove-Item -LiteralPath $script:StopFile -Force -ErrorAction SilentlyContinue
    }
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:EnginePath) `
        -WindowStyle Hidden | Out-Null
    return 'started'
}

function Stop-GameMode {
    if (-not (Test-ManagerRunning)) { return 'not-running' }
    Set-Content -LiteralPath $script:StopFile -Value ((Get-Date).ToString('s')) -Encoding ASCII
    foreach ($i in 1..60) {
        if (-not (Test-ManagerRunning)) { return 'stopped' }
        Start-Sleep -Milliseconds 500
        [System.Windows.Forms.Application]::DoEvents()
    }
    return 'timeout'
}

# ---------------------------------------------------------------- 重拨模式

function Get-RedialArgs {
    if ($script:RadioTestOnly.Checked) { return @('-TestOnly') }
    if ($script:RadioHighBandwidth.Checked) { return @('-HighBandwidthMode') }
    return @()
}

function Start-Redial {
    if ($script:RedialProc -and -not $script:RedialProc.HasExited) { return 'already' }
    if (Test-ManagerRunning) { return 'game-running' }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:RedialOutFile = Join-Path $script:LogDir ("redial-$stamp.out.txt")
    $script:RedialErrFile = Join-Path $script:LogDir ("redial-$stamp.err.txt")
    # 给子进程一个**空的 stdin**：重拨脚本找到好出口后会 Read-Host 问"要不要继续"，
    # 读到 EOF 就按"其它键"处理并正常退出 —— GUI 里没有键盘给它。
    $script:RedialStdinFile = Join-Path $env:TEMP ("redial-$stamp.in.txt")
    Set-Content -LiteralPath $script:RedialStdinFile -Value '' -Encoding ASCII

    $script:RedialAllText = ''
    $script:TailOffsets = @{}
    $script:RedialDone = $false
    $script:RedialStartedAt = Get-Date   # 「已持续」从这里起算
    $script:RedialAttempts = 0           # 「已尝试 N 次」每个 run 从 0 起

    $argl = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:RedialPath) + (Get-RedialArgs)
    $script:RedialArgText = if ((Get-RedialArgs).Count) { (Get-RedialArgs) -join ' ' } else { '（默认：重拨到好出口）' }
    $script:RedialProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argl -PassThru `
        -WindowStyle Hidden -RedirectStandardOutput $script:RedialOutFile `
        -RedirectStandardError $script:RedialErrFile -RedirectStandardInput $script:RedialStdinFile
    Add-LogLine ('重拨模式已启动（{0}，pid={1}）。' -f $script:RedialArgText, $script:RedialProc.Id)
    return 'started'
}

function Stop-Redial {
    param([string]$Reason = '你点了停止')

    if (-not $script:RedialProc -or $script:RedialProc.HasExited) { return 'not-running' }
    try { $script:RedialProc.Kill() } catch { }
    foreach ($i in 1..20) {
        Start-Sleep -Milliseconds 250
        if ($script:RedialProc.HasExited) { break }
    }
    Add-LogLine ('重拨模式已停止（{0}）。' -f $Reason)

    # 重拨脚本是先 disconnect 再 connect 的，如果在"断开之后、拨上之前"被杀，
    # 拨号会留在断开状态 —— 补拨一次，避免用户莫名其妙回到没拨号的状态。
    $st = Get-StatusObject -Fresh
    if ($st -and -not $st.dialConnected -and $st.dialName) {
        Add-LogLine ('检测到拨号是断开的，补拨一次：{0}' -f $st.dialName)
        try { & rasdial.exe $st.dialName | Out-Null } catch { }
    }
    return 'stopped'
}

function Update-Redial {
    if (-not $script:RedialOutFile) { return }

    Append-NewOutput -Path $script:RedialOutFile -Tag '重拨'
    Append-NewOutput -Path $script:RedialErrFile -Tag '重拨!'

    $running = ($script:RedialProc -and -not $script:RedialProc.HasExited)

    # 脚本找到好出口后会打印"好了喵"，然后停在 Read-Host 等你按键 ——
    # GUI 里没有键盘给它，所以看到这句就当作完成，顺手把那个进程收掉（此时拨号是连着的，杀掉没有副作用）。
    if ($running -and $script:RedialAllText -like '*好了喵*') {
        try { $script:RedialProc.Kill() } catch { }
        Start-Sleep -Milliseconds 300
        $script:RedialDone = $true
        Add-LogLine '重拨模式：已确认拿到好出口（好了喵）—— 本次完成。'
        $running = $false
    }

    if (-not $running -and -not $script:RedialDone -and $script:RedialProc) {
        # 不看退出码（Start-Process -PassThru 拿不到），直接看脚本自己打印的结论 —— 反而更准。
        $t = $script:RedialAllText
        $verdict =
        if ($t -like '*Current exit is a good campus-network exit*') { '当前出口是**好出口**（只测完成）' }
        elseif ($t -like '*Current exit is a bad campus-network exit*') { '当前出口是**坏出口**（只测完成）' }
        elseif ($t -like '*已达到*Mbps 目标*') { '已达速，高速模式完成' }
        elseif ($t -like '*No good exit was found*') { '尝试次数用完，没找到好出口（失败）' }
        elseif ($t -like '*好了喵*') { '找到好出口并确认，完成' }
        else { '进程已退出 —— 结论看上面的输出' }
        Add-LogLine ('重拨模式：结束 —— {0}' -f $verdict)
        $script:RedialDone = $true
    }
}

function Append-NewOutput {
    param([string]$Path, [string]$Tag)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    $text = ''
    # 用 ANSI 码页读：子进程被重定向时按系统 ANSI 码页写，不是 UTF-8。
    try { $text = [IO.File]::ReadAllText($Path, $script:ChildEncoding) } catch { return }
    if (-not $script:TailOffsets.ContainsKey($Tag)) { $script:TailOffsets[$Tag] = 0 }
    $off = $script:TailOffsets[$Tag]
    if ($text.Length -lt $off) { $off = 0 }
    if ($text.Length -eq $off) { return }
    $new = $text.Substring($off)
    $script:TailOffsets[$Tag] = $text.Length
    if ($Tag -eq '重拨') {
        $script:RedialAllText += $new
        # 重拨脚本每换一个出口就会打一行 "Attempt N"（高速模式是"第 N 次连接尝试"）——
        # 把最大的那个数抓到，界面就能显示"已尝试 N 次"，没成功时它只会往上加。
        foreach ($m in [regex]::Matches($new, 'Attempt\s+(\d+)|第\s*(\d+)\s*次连接尝试')) {
            $v = if ($m.Groups[1].Success) { [int]$m.Groups[1].Value } else { [int]$m.Groups[2].Value }
            if ($v -gt $script:RedialAttempts) { $script:RedialAttempts = $v }
        }
    }
    foreach ($line in ($new -split "`r?`n")) {
        $t = $line.TrimEnd()
        if ($t) { Add-LogLine ('[{0}] {1}' -f $Tag, $t) }
    }
}

# ---------------------------------------------------------------- 界面

$form = New-Object System.Windows.Forms.Form
$form.Text = '校园网网络管理器'
$form.Size = New-Object System.Drawing.Size(560, 745)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

$fontUi = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$fontMono = New-Object System.Drawing.Font('Consolas', 9)

function New-UiLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H = 22, [bool]$Bold = $false, [System.Drawing.Color]$Color = [System.Drawing.Color]::Black)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, $H)
    $l.Font = if ($Bold) { New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold) } else { $fontUi }
    $l.ForeColor = $Color
    return $l
}

$form.Controls.Add((New-UiLabel -Text '实时状态' -X 16 -Y 12 -W 200 -Bold $true))

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(16, 36)
$lblStatus.Size = New-Object System.Drawing.Size(505, 140)
$lblStatus.Font = $fontMono
$lblStatus.Text = '读取中...'
$form.Controls.Add($lblStatus)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = '重新检测'
$btnRefresh.Location = New-Object System.Drawing.Point(410, 178)
$btnRefresh.Size = New-Object System.Drawing.Size(110, 26)
$form.Controls.Add($btnRefresh)

# ---------------------------------------------------------------- 模式（两个标签页）

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(16, 208)
$tabs.Size = New-Object System.Drawing.Size(508, 292)
$tabs.Font = $fontUi
$form.Controls.Add($tabs)

# ---- 标签页 1：正常重拨模式
$pageRedial = New-Object System.Windows.Forms.TabPage
$pageRedial.Text = '正常重拨模式'
$pageRedial.UseVisualStyleBackColor = $true
$tabs.Controls.Add($pageRedial)

$pageRedial.Controls.Add((New-UiLabel -Text '重新拨号，直到三轮探测确认拿到好出口。' -X 12 -Y 10 -W 470))

$grpMode = New-Object System.Windows.Forms.GroupBox
$grpMode.Text = '运行方式'
$grpMode.Location = New-Object System.Drawing.Point(12, 38)
$grpMode.Size = New-Object System.Drawing.Size(470, 100)
$grpMode.Font = $fontUi
$pageRedial.Controls.Add($grpMode)

$script:RadioPlain = New-Object System.Windows.Forms.RadioButton
$script:RadioPlain.Text = '普通重拨（默认）：一直换出口，直到拿到好出口'
$script:RadioPlain.Location = New-Object System.Drawing.Point(12, 20)
$script:RadioPlain.Size = New-Object System.Drawing.Size(440, 22)
$script:RadioPlain.Font = $fontUi
$script:RadioPlain.Checked = $true
$grpMode.Controls.Add($script:RadioPlain)

$script:RadioTestOnly = New-Object System.Windows.Forms.RadioButton
$script:RadioTestOnly.Text = '只测当前出口：不拨号，只判断现在这条好不好'
$script:RadioTestOnly.Location = New-Object System.Drawing.Point(12, 44)
$script:RadioTestOnly.Size = New-Object System.Drawing.Size(440, 22)
$script:RadioTestOnly.Font = $fontUi
$grpMode.Controls.Add($script:RadioTestOnly)

$script:RadioHighBandwidth = New-Object System.Windows.Forms.RadioButton
$script:RadioHighBandwidth.Text = '高速模式：重拨到西电测速超过 150 Mbps'
$script:RadioHighBandwidth.Location = New-Object System.Drawing.Point(12, 68)
$script:RadioHighBandwidth.Size = New-Object System.Drawing.Size(440, 22)
$script:RadioHighBandwidth.Font = $fontUi
$grpMode.Controls.Add($script:RadioHighBandwidth)

$btnRedialStart = New-Object System.Windows.Forms.Button
$btnRedialStart.Text = '开始'
$btnRedialStart.Location = New-Object System.Drawing.Point(12, 146)
$btnRedialStart.Size = New-Object System.Drawing.Size(96, 30)
$pageRedial.Controls.Add($btnRedialStart)

$btnRedialStop = New-Object System.Windows.Forms.Button
$btnRedialStop.Text = '停止'
$btnRedialStop.Location = New-Object System.Drawing.Point(116, 146)
$btnRedialStop.Size = New-Object System.Drawing.Size(96, 30)
$btnRedialStop.Enabled = $false
$pageRedial.Controls.Add($btnRedialStop)

$lblRedialState = New-Object System.Windows.Forms.Label
$lblRedialState.Location = New-Object System.Drawing.Point(224, 152)
$lblRedialState.Size = New-Object System.Drawing.Size(258, 22)
$lblRedialState.Font = $fontUi
$lblRedialState.ForeColor = [System.Drawing.Color]::DimGray
$lblRedialState.Text = '未运行'
$pageRedial.Controls.Add($lblRedialState)

$lblRedialHint = New-Object System.Windows.Forms.Label
$lblRedialHint.Location = New-Object System.Drawing.Point(12, 182)
$lblRedialHint.Size = New-Object System.Drawing.Size(470, 40)
$lblRedialHint.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$lblRedialHint.ForeColor = [System.Drawing.Color]::DimGray
$lblRedialHint.Text = '输出会实时显示在下面的日志区；这次的完整输出另外留在 logs\redial-*.out.txt。'
$pageRedial.Controls.Add($lblRedialHint)

# ---- 标签页 2：游戏模式
$pageGame = New-Object System.Windows.Forms.TabPage
$pageGame.Text = '游戏模式'
$pageGame.UseVisualStyleBackColor = $true
$tabs.Controls.Add($pageGame)

$pageGame.Controls.Add((New-UiLabel -Text '常驻后台：Wi-Fi 保底 + 拨号主用自动切换，换出口时你几乎无感。' -X 12 -Y 10 -W 470))

$chkAutoStart = New-Object System.Windows.Forms.CheckBox
$chkAutoStart.Text = '开机自启（登录后自动开游戏模式，走最高权限计划任务）'
$chkAutoStart.Location = New-Object System.Drawing.Point(14, 40)
$chkAutoStart.Size = New-Object System.Drawing.Size(460, 24)
$chkAutoStart.Font = $fontUi
$pageGame.Controls.Add($chkAutoStart)

$btnGameToggle = New-Object System.Windows.Forms.Button
$btnGameToggle.Text = '开启游戏模式'
$btnGameToggle.Location = New-Object System.Drawing.Point(12, 74)
$btnGameToggle.Size = New-Object System.Drawing.Size(150, 34)
$pageGame.Controls.Add($btnGameToggle)

$lblGameHint = New-Object System.Windows.Forms.Label
$lblGameHint.Location = New-Object System.Drawing.Point(12, 116)
$lblGameHint.Size = New-Object System.Drawing.Size(470, 84)
$lblGameHint.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$lblGameHint.ForeColor = [System.Drawing.Color]::DimGray
$lblGameHint.Text = '只保证一直都有可用网络，可能会在校园网与热点之间切换，不保证游戏时的稳定性。'
$pageGame.Controls.Add($lblGameHint)

# ---------------------------------------------------------------- 日志区 + 共用工具

$form.Controls.Add((New-UiLabel -Text '日志' -X 16 -Y 508 -W 200 -Bold $true))

$txtOutput = New-Object System.Windows.Forms.TextBox
$txtOutput.Location = New-Object System.Drawing.Point(16, 530)
$txtOutput.Size = New-Object System.Drawing.Size(508, 126)
$txtOutput.Multiline = $true
$txtOutput.ReadOnly = $true
$txtOutput.ScrollBars = 'Vertical'
$txtOutput.Font = $fontMono
$txtOutput.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($txtOutput)

$btnRestore = New-Object System.Windows.Forms.Button
$btnRestore.Text = '恢复拨号优先'
$btnRestore.Location = New-Object System.Drawing.Point(16, 664)
$btnRestore.Size = New-Object System.Drawing.Size(121, 30)
$form.Controls.Add($btnRestore)

$btnBoth = New-Object System.Windows.Forms.Button
$btnBoth.Text = '测一轮双出口'
$btnBoth.Location = New-Object System.Drawing.Point(145, 664)
$btnBoth.Size = New-Object System.Drawing.Size(121, 30)
$form.Controls.Add($btnBoth)

# 一个按钮干两件事：拨号连着就断开、断开就拨上（标签跟着状态变）。
# 断开不碰电话簿开关 —— 下次拨上来照样是"拨号优先"。
$btnDial = New-Object System.Windows.Forms.Button
$btnDial.Text = '断开拨号'
$btnDial.Location = New-Object System.Drawing.Point(274, 664)
$btnDial.Size = New-Object System.Drawing.Size(121, 30)
$form.Controls.Add($btnDial)

# 真正退出（和托盘右键那个「退出」一个动作：会先问要不要连模式一起停）
$btnExit = New-Object System.Windows.Forms.Button
$btnExit.Text = '退出'
$btnExit.Location = New-Object System.Drawing.Point(403, 664)
$btnExit.Size = New-Object System.Drawing.Size(121, 30)
$form.Controls.Add($btnExit)

function Add-LogLine {
    param([string]$Text)
    # **先落盘再写界面**：界面那半句万一抛（控件状态异常之类），日志不该跟着一起丢。
    try {
        $logFile = Join-Path $script:LogDir 'ui.log'
        # 注意别写成 `if (Test-Path X -and (Get-Item X).Length ...)`：
        # -and 会被当成 Test-Path 的参数，后面的 Get-Item **无条件求值**、短路失效，
        # 文件不存在时直接抛 ItemNotFoundException —— 实测踩过，整句日志都会没。
        if (Test-Path -LiteralPath $logFile) {
            if ((Get-Item -LiteralPath $logFile).Length -gt 256KB) {
                Move-Item -LiteralPath $logFile -Destination (Join-Path $script:LogDir 'ui.log.1') -Force
            }
        }
        [IO.File]::AppendAllText($logFile,
            ('{0} {1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text, [Environment]::NewLine),
            [Text.UTF8Encoding]::new($false))
    }
    catch { }
    try { $txtOutput.AppendText(('[{0}] {1}{2}' -f (Get-Date -Format 'HH:mm:ss'), $Text, [Environment]::NewLine)) } catch { }
}

# ---------------------------------------------------------------- 刷新

$script:SuppressEvents = $false
$script:RedialProc = $null
$script:RedialOutFile = $null
$script:RedialErrFile = $null
$script:RedialAllText = ''
$script:RedialDone = $false
$script:TailOffsets = @{}
$script:LastStatus = $null
$script:FreshStatusDue = [datetime]::MinValue
$script:CarrierEvidence = ''   # 「重新检测」时做一次行为确认（curl 看源地址），显示在状态面板最后一行
$script:RedialStartedAt = $null         # 重拨模式这一轮的起点（用来算"已持续"）
$script:RedialAttempts = 0              # 从重拨脚本输出里抓到的"第几次尝试"
$script:EngineRunningForStatus = $false # 面板上的时长只在引擎真的在跑时外推，否则会一直往上飘

function Format-Elapsed {
    # 和引擎控制台那行一个口径：X 分 Y 秒 / X 小时 Y 分 Y 秒
    param([int]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $h = [int][Math]::Floor($Seconds / 3600)
    $m = [int][Math]::Floor(($Seconds % 3600) / 60)
    $s = $Seconds % 60
    if ($h -gt 0) { return ('{0} 小时 {1} 分 {2} 秒' -f $h, $m, $s) }
    if ($m -gt 0) { return ('{0} 分 {1} 秒' -f $m, $s) }
    return ('{0} 秒' -f $s)
}

function Format-StatusText {
    param([pscustomobject]$S)

    $carrierText = switch -Wildcard ($S.carrier) {
        'pppoe' { '拨号（校园网）' }
        'wifi' { 'Wi-Fi（热点）' }
        default { [string]$S.carrier }
    }
    # 把引擎内部的状态名翻成人话 —— 原来直接把 parked/primary 打出来，
    # 再加上"流量跟着 Wi-Fi 走"那句固定文案，主用时会显得自相矛盾。
    $stateText = switch -Wildcard ($S.state) {
        'idle' { '未运行' }
        'starting' { '启动中' }
        'dialing' { '正在拨号换出口：流量还在 Wi-Fi 上，你不受影响' }
        'verifying' { '正在验证出口' }
        'parked' { '停放中：流量走 Wi-Fi，拨号在后台当候选' }
        'primary' { '主用中：流量走拨号' }
        'stopping' { '正在停止' }
        'stopped' { '已停止' }
        default { [string]$S.state }
    }
    $dialText = if ($S.dialConnected) { ('已连接 {0}' -f $S.dialIp) } else { '未连接' }
    # 主用时拨号是引擎临时加的路由，电话簿开关仍然是 0，所以别把 0 一律叫"停放态"。
    $parkText = if ($S.parkSwitch -eq '0') {
        '0（拨号自己不装默认路由；引擎要切主用时才临时加一条）'
    }
    else { '1（拨号一连上就是默认网关）' }
    # 这一对刻意分开显示：电话簿说"停放"、而拨号仍握着默认路由，就是引擎在主用。
    $holdsText = if ($S.dialHoldsDefault) { '是' } else { '否' }
    # 「健康已持续」要每秒都在走：引擎每轮才重写一次状态，所以这里按状态里的时间戳本地外推。
    # 只在引擎确实在跑时外推（否则引擎一停这个数会一直往上飘），并且最多补 20 秒。
    $healthSecs = 0
    if ($S.healthySeconds) { $healthSecs = [int]$S.healthySeconds }
    if ($healthSecs -gt 0 -and $script:EngineRunningForStatus) {
        try {
            $takenAt = [datetime]::ParseExact([string]$S.time, 'yyyy-MM-dd HH:mm:ss', $null)
            $delta = ((Get-Date) - $takenAt).TotalSeconds
            if ($delta -gt 0) { $healthSecs += [int][Math]::Floor([Math]::Min($delta, 20)) }
        }
        catch { }
    }
    $healthyText = if ($healthSecs -gt 0) { Format-Elapsed -Seconds $healthSecs } else { '—' }

    $lines = @(
        ('当前承载   ：{0}' -f $carrierText)
        ('运行状态   ：{0}' -f $stateText)
        ('健康已持续 ：{0}' -f $healthyText)
        ('最近检查   ：{0}' -f $(if ($S.lastCheck) { $S.lastCheck } else { '—' }))
        ('拨号       ：{0}' -f $dialText)
        ('拨号尝试   ：本会话第 {0} 次{1}' -f [int]$S.dialAttempts, $(if ([int]$S.dialFailStreak -gt 0) { ('（当前连续失败 {0} 次）' -f [int]$S.dialFailStreak) } else { '' }))
        ('电话簿开关 ：{0}' -f $parkText)
        ('拨号握默认 ：{0}' -f $holdsText)
        ('Wi-Fi      ：{0} {1} {2}   保底可用：{3}' -f $S.wifiName, $S.wifiStatus, $S.wifiIp, $(if ($S.wifiAlive) { '是' } else { '否' }))
    )
    if ($script:CarrierEvidence) { $lines += ('行为确认   ：{0}' -f $script:CarrierEvidence) }
    $lines += ('状态时间   ：{0}' -f $S.time)
    return ($lines -join [Environment]::NewLine)
}

function Get-CarrierEvidence {
    # "当前承载"是路由表算出来的（预选），这里补一次**行为真相**：发一个请求，看源地址是哪条路。
    # 这是唯一可信的判据（路由表在两种"没有默认路由"的状态下会说谎）。
    param([pscustomobject]$S)
    if (-not $S) { return '拿不到状态，没法做行为确认' }
    try {
        $raw = & curl.exe -s -o NUL --max-time 6 -4 -w '%{http_code}|%{local_ip}' 'https://kernel.org/'
    }
    catch { return '行为确认失败：curl 起不来' }
    $parts = ([string]$raw) -split '\|'
    $src = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
    if (-not $src) { return '没拿到源地址（目标不可达？）' }
    $which = if ($src -eq $S.dialIp) { '拨号' } elseif ($src -eq $S.wifiIp) { 'Wi-Fi' } else { ('未知接口 ' + $src) }
    $match = if (($S.carrier -eq 'pppoe' -and $which -eq '拨号') -or ($S.carrier -eq 'wifi' -and $which -eq 'Wi-Fi')) { '与上面的承载一致 ✓' } else { '⚠ 与上面的承载不一致！' }
    return ('这次请求源地址 = {0}（{1}）{2}' -f $src, $which, $match)
}

function Update-UiStates {
    param([pscustomobject]$S)

    $gameRunning = Test-ManagerRunning
    $redialRunning = [bool]($script:RedialProc -and -not $script:RedialProc.HasExited)
    $wifiOk = [bool]($S -and $S.wifiAlive)

    $script:SuppressEvents = $true
    try {
        # ---- 重拨模式
        $btnRedialStart.Enabled = (-not $redialRunning) -and (-not $gameRunning)
        $btnRedialStop.Enabled = $redialRunning
        $script:RadioPlain.Enabled = -not $redialRunning
        $script:RadioTestOnly.Enabled = -not $redialRunning
        $script:RadioHighBandwidth.Enabled = -not $redialRunning

        if ($redialRunning) {
            # 定时器 1 秒一轮，所以这两项是每秒在走字的：已尝试几次 + 已持续多久。
            $elapsed = '—'
            if ($script:RedialStartedAt) {
                $elapsed = Format-Elapsed -Seconds ([int]((Get-Date) - $script:RedialStartedAt).TotalSeconds)
            }
            $lblRedialState.Text = ('运行中 · 尝试 {0} 次 · {1}' -f $script:RedialAttempts, $elapsed)
            $lblRedialState.ForeColor = [System.Drawing.Color]::DarkGreen
            $lblRedialHint.Text = '正在跑，日志区会实时更新；要停就点「停止」。'
        }
        elseif ($gameRunning) {
            $lblRedialState.Text = '被游戏模式占用'
            $lblRedialState.ForeColor = [System.Drawing.Color]::Firebrick
            $lblRedialHint.Text = '游戏模式在跑（两个模式都要动拨号，所以互斥）。先关掉游戏模式再重拨。'
        }
        elseif ($script:RedialDone) {
            $lblRedialState.Text = '已结束（看日志区）'
            $lblRedialState.ForeColor = [System.Drawing.Color]::DimGray
            $lblRedialHint.Text = '输出会实时显示在下面的日志区；这次的完整输出另外留在 logs\redial-*.out.txt。'
        }
        else {
            $lblRedialState.Text = '未运行'
            $lblRedialState.ForeColor = [System.Drawing.Color]::DimGray
            $lblRedialHint.Text = '输出会实时显示在下面的日志区；这次的完整输出另外留在 logs\redial-*.out.txt。'
        }

        # ---- 游戏模式
        $btnGameToggle.Text = if ($gameRunning) { '关闭游戏模式' } else { '开启游戏模式' }
        # 热点没连时置灰；已经在跑时不置灰，否则热点掉了用户就没法从界面把它关掉。
        $btnGameToggle.Enabled = (-not $redialRunning) -and ($wifiOk -or $gameRunning)
        $chkAutoStart.Enabled = -not $redialRunning

        if ($gameRunning) {
            # 文案必须跟着真实状态走：原来固定写"流量跟着 Wi-Fi 走"，
            # 可一旦它把拨号晋升成主用（state=primary），那句话就是错的。
            $modeLine = switch -Wildcard ([string]$S.state) {
                'primary' { '游戏模式运行中：【拨号正在承载】—— 这个出口已通过三轮验证；变坏会立刻退回 Wi-Fi。' }
                'parked' { '游戏模式运行中：【流量走 Wi-Fi】—— 拨号在后台当候选，确认到好出口才会切过去。' }
                'dialing' { '游戏模式运行中：正在换出口（流量还在 Wi-Fi 上，你不受影响）。' }
                'verifying' { '游戏模式运行中：正在验证新出口（还在 Wi-Fi 上）。' }
                default { '游戏模式运行中：正在启动或切换（看上面的状态行）。' }
            }
            $lblGameHint.Text = $modeLine + [Environment]::NewLine + '只保证一直都有可用网络，可能会在校园网与热点之间切换，不保证游戏时的稳定性。'
            $lblGameHint.ForeColor = [System.Drawing.Color]::DimGray
        }
        elseif ($redialRunning) {
            $lblGameHint.Text = '重拨模式在跑（两个模式都要动拨号，所以互斥）。先停掉重拨再开游戏模式。'
            $lblGameHint.ForeColor = [System.Drawing.Color]::Firebrick
        }
        elseif (-not $wifiOk) {
            $lblGameHint.Text = '⚠ 请先连上热点（Wi-Fi）再开游戏模式：它靠"把拨号停放到 Wi-Fi 旁边"工作，没有 Wi-Fi 会让流量没有出路。'
            $lblGameHint.ForeColor = [System.Drawing.Color]::Firebrick
        }
        else {
            $lblGameHint.Text = '只保证一直都有可用网络，可能会在校园网与热点之间切换，不保证游戏时的稳定性。'
            $lblGameHint.ForeColor = [System.Drawing.Color]::DimGray
        }

        # ---- 拨号开关按钮：跑着模式时别去跟它们抢拨号
        $btnDial.Enabled = (-not $redialRunning) -and (-not $gameRunning)
        $btnDial.Text = if ($S -and $S.dialConnected) { '断开拨号' } else { '拨号' }
    }
    finally { $script:SuppressEvents = $false }
}

function Update-AutoStartSwitch {
    $r = Invoke-Hidden -Target @($script:AutoStartPath, '-StatusJson') -TimeoutSeconds 30
    $script:SuppressEvents = $true
    try {
        try { $chkAutoStart.Checked = [bool](($r.Output | ConvertFrom-Json).manager) } catch { }
    }
    finally { $script:SuppressEvents = $false }
}

function Update-Status {
    # 定时调用。要点：**管理器没在跑的时候不能信 logs\status.json** ——
    # 那是上一次运行留下的快照，可能过期很久（实测碰到过面板显示一天前的状态，
    # 表现就是"明明连着 Wi-Fi 却开不了游戏模式"）。没在跑就自己实时查，但别每秒起进程：最多 8 秒一次。
    param([switch]$Fresh)

    $s = $null
    $script:EngineRunningForStatus = Test-ManagerRunning
    if ($script:EngineRunningForStatus) {
        # 管理器在跑：status.json 每轮都在重写，读文件最省。
        $s = Get-StatusObject
    }
    elseif ($Fresh -or $script:FreshStatusDue -le (Get-Date)) {
        $script:FreshStatusDue = (Get-Date).AddSeconds(8)
        $s = Get-StatusObject -Fresh
    }

    if (-not $s) { $s = $script:LastStatus }   # 这次没查到就先用上一次的
    if (-not $s) {
        $lblStatus.Text = '正在读取状态…（管理器没在跑时每 8 秒实时查一次）'
        Update-UiStates -S $null
        return $null
    }
    $script:LastStatus = $s
    $lblStatus.Text = Format-StatusText -S $s
    Update-UiStates -S $s
    return $s
}

# ---------------------------------------------------------------- 事件

$btnRefresh.Add_Click({
    $s = Get-StatusObject -Fresh
    if ($s) {
        $script:LastStatus = $s
        # 顺手做一次行为确认：路由表只能"预选"，源地址才是真相。
        $script:CarrierEvidence = Get-CarrierEvidence -S $s
    }
    Update-Status | Out-Null
    Update-AutoStartSwitch
    Add-LogLine ('已重新检测。行为确认：' + $script:CarrierEvidence)
})

$btnRedialStart.Add_Click({
    $r = Start-Redial
    switch ($r) {
        'game-running' {
            [System.Windows.Forms.MessageBox]::Show(
                '游戏模式正在跑。两个模式都会动拨号，同时跑会互相抢，所以只能开一个。',
                '先关掉游戏模式', 'OK', 'Warning') | Out-Null
        }
        'already' { Add-LogLine '重拨模式已经在跑了。' }
    }
    Update-Status -Fresh | Out-Null
})

$btnRedialStop.Add_Click({
    [void](Stop-Redial)
    Update-Status -Fresh | Out-Null
})

$btnGameToggle.Add_Click({
    if (Test-ManagerRunning) {
        $r = Stop-GameMode
        if ($r -eq 'stopped') {
            Add-LogLine '游戏模式已关闭（优雅退出：电话簿开关会还原成拨号优先）。'
        }
        else {
            Add-LogLine '停止超时：管理器还在跑。可以再点一次，或直接结束那个进程。'
        }
    }
    else {
        $r = Start-GameMode
        switch ($r) {
            'started' { Add-LogLine '游戏模式已开启（管理器在后台运行；它会自己请求提权）。' }
            'no-wifi' {
                # 别咬定"热点没连" —— 可能是 Wi-Fi 网卡/路由有、只是这一次网关 ping 不通。
                # 把当下的事实一起打出来，免得用户对着"请先连热点"发呆。
                $d = $script:LastStatus
                $detail = if ($d) {
                    ('Wi-Fi「{0}」状态 {1}、IP {2}；网关探测没通过（每 8 秒会自动重查）' -f $d.wifiName, $d.wifiStatus, $d.wifiIp)
                }
                else { '读不到 Wi-Fi 状态' }
                Add-LogLine ('开不了游戏模式：判定 Wi-Fi（热点）当前不可用 —— {0}' -f $detail)
                [System.Windows.Forms.MessageBox]::Show(
                    ('游戏模式需要 Wi-Fi（热点）可用。' + [Environment]::NewLine + [Environment]::NewLine +
                     '它靠"把拨号停放到 Wi-Fi 旁边、流量跑在 Wi-Fi 上、拨号只做后台候选"工作；' + [Environment]::NewLine +
                     '没有 Wi-Fi 时停放等于把流量丢进黑洞（拨号让出了默认路由，而 Wi-Fi 给不出路由）。' + [Environment]::NewLine + [Environment]::NewLine +
                     ('当前：' + $detail) + [Environment]::NewLine + [Environment]::NewLine +
                     '如果热点明明是连着的，点一下「重新检测」再看；还不行就看下面日志区/ logs\ui.log。'),
                    'Wi-Fi（热点）当前不可用', 'OK', 'Warning') | Out-Null
            }
        }
    }
    Update-Status -Fresh | Out-Null
})

$chkAutoStart.Add_CheckedChanged({
    if ($script:SuppressEvents) { return }

    $want = if ($chkAutoStart.Checked) { 'On' } else { 'Off' }
    $r = Invoke-Hidden -Target @($script:AutoStartPath, '-ManagerAutostart', $want) -TimeoutSeconds 120
    $msg = @($r.Output -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 1)
    Add-LogLine ('开机自启 -> {0}：{1}' -f $want, $(if ($msg.Count) { $msg[0].Trim() } else { '退出码 ' + $r.ExitCode }))
    Update-AutoStartSwitch
})

$btnRestore.Add_Click({
    $r = Invoke-Hidden -Target @($script:EnginePath, '-RestoreDialPriority') -TimeoutSeconds 180
    $line = @($r.Output -split "`r?`n" | Where-Object { $_ -match '已|失败|目标' } | Select-Object -Last 1)
    Add-LogLine ('恢复拨号优先：{0}' -f $(if ($line.Count) { $line[0].Trim() } else { '退出码 ' + $r.ExitCode }))
    Update-Status -Fresh | Out-Null
})

$btnBoth.Add_Click({
    Add-LogLine '正在测两个出口（各一次探针 + 出口源地址确认）...'
    [System.Windows.Forms.Application]::DoEvents()
    $r = Invoke-Hidden -Target @($script:BothExitsPath, '-Once', '-Json') -TimeoutSeconds 240
    try {
        $j = $r.Output | ConvertFrom-Json
        Add-LogLine ('  拨号  {0}  {1}  通过 {2}/{3}  源={4}' -f $j.dial.ip, $(if ($j.dial.ok) { '可用' } else { '不可用' }), $j.dial.passed, $j.dial.total, $j.dial.egress)
        Add-LogLine ('  Wi-Fi {0}  {1}  通过 {2}/{3}  源={4}' -f $j.wifi.ip, $(if ($j.wifi.ok) { '可用' } else { '不可用' }), $j.wifi.passed, $j.wifi.total, $j.wifi.egress)
        Add-LogLine ('  => {0}' -f $j.verdict)
    }
    catch {
        Add-LogLine ('测一轮失败：拿不到 JSON（退出码 {0}）。原始输出：{1}' -f $r.ExitCode, ($r.Output -replace "`r?`n", ' '))
    }
    Update-Status -Fresh | Out-Null
})

$btnDial.Add_Click({
    $st = Get-StatusObject -Fresh
    if ($st) { $script:LastStatus = $st }
    elseif ($script:LastStatus) { $st = $script:LastStatus }
    if (-not $st -or -not $st.dialName) {
        Add-LogLine '拿不到拨号连接名，先点一下「重新检测」。'
        return
    }

    if (-not $st.dialConnected) {
        Add-LogLine ('拨号（{0}）现在是断开的，正在拨上…' -f $st.dialName)
        & rasdial.exe $st.dialName | Out-Null
        Add-LogLine ('  结果：rasdial 退出码 {0}。连上后拨号重新成为默认网关（电话簿开关 = {1}）。' -f $LASTEXITCODE, $st.parkSwitch)
    }
    else {
        Add-LogLine ('正在断开拨号（{0}）…' -f $st.dialName)
        & rasdial.exe $st.dialName /disconnect | Out-Null
        Add-LogLine ('  结果：rasdial 退出码 {0}。流量现在走 Wi-Fi；电话簿开关不变（{1}），所以下次拨上来仍是拨号优先。' -f $LASTEXITCODE, $st.parkSwitch)
    }
    Update-Status -Fresh | Out-Null
})

# ---------------------------------------------------------------- 图标 / 托盘 / 退出

# 图标：exe 里内嵌了 app.ico，启动时解到脚本旁边，这里拿它当窗口图标和托盘图标。
# 文件不在也不影响使用（退回系统默认图标）。
$iconPath = Join-Path $script:Root 'app.ico'
$script:TrayIcon = $null
if (Test-Path -LiteralPath $iconPath) {
    try { $form.Icon = New-Object System.Drawing.Icon($iconPath) } catch { }
    # 托盘只有 16×16 大小，单独取那一帧比缩放 32×32 清楚
    try { $script:TrayIcon = New-Object System.Drawing.Icon($iconPath, 16, 16) } catch { }
}

function Exit-App {
    # 「是」= 退出，并把正在跑的模式一起停掉；「否」= 什么都不做。
    # （原来是三选一、"是"反而表示"只关界面"，可 MessageBox 的按钮标签自带
    #   "是/否"的固有含义，自定义语义很容易点反 —— 实测就点反了。）
    $gameRunning = Test-ManagerRunning
    $redialRunning = [bool]($script:RedialProc -and -not $script:RedialProc.HasExited)
    if ($gameRunning -or $redialRunning) {
        $names = @()
        if ($gameRunning) { $names += '游戏模式' }
        if ($redialRunning) { $names += '重拨模式' }
        $msg = ('要退出吗？正在跑的 {0} 会一起停掉（管理器走优雅退出，把电话簿还原成拨号优先）。' -f ($names -join ' 和 '))
        $answer = [System.Windows.Forms.MessageBox]::Show($msg, '退出', 'YesNo', 'Question')
        if ($answer -ne 'Yes') { return }
        if ($redialRunning) { [void](Stop-Redial -Reason '退出时一起停掉') }
        if ($gameRunning) { [void](Stop-GameMode) }
    }
    $script:ReallyExiting = $true
    try { Add-LogLine '正在退出。' } catch { }
    try { $timer.Stop() } catch { }
    try { $tray.Visible = $false; $tray.Dispose() } catch { }
    $form.Close()
}

# 托盘：关窗口只是收起来，右键托盘才真退出
$script:ReallyExiting = $false
$script:BalloonShown = $false

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Text = '校园网网络管理器'
$tray.Icon = if ($script:TrayIcon) { $script:TrayIcon } elseif ($form.Icon) { $form.Icon } else { [System.Drawing.SystemIcons]::Application }
$tray.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = $trayMenu.Items.Add('打开界面')
[void]$trayMenu.Items.Add('-')
$miExit = $trayMenu.Items.Add('退出')
$tray.ContextMenuStrip = $trayMenu

# 记一条日志：万一托盘里找不到图标，至少能从这里确认"图标确实创建了"。
Add-LogLine ('托盘图标已创建（{0}）。Win11 默认把新托盘图标收进折叠区，记得拖出来钉住。任务栏身份 hr={1}' -f $(
    if ($script:TrayIcon) { 'app.ico 的 16×16 帧' }
    elseif ($form.Icon) { 'app.ico 的默认帧' }
    else { '系统默认图标（没找到 app.ico）' }), $(if ($null -ne $script:AppIdResult) { ('0x{0:X}' -f $script:AppIdResult) } else { '未设置' }))

$showWindow = {
    $form.Show()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    [void]$form.Activate()
}
$miOpen.Add_Click($showWindow)
$tray.Add_MouseDoubleClick($showWindow)
$miExit.Add_Click({ Exit-App })
$btnExit.Add_Click({ Exit-App })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    Update-Status | Out-Null
    Update-Redial
})
$timer.Start()

$form.Add_Shown({
    try {
        $s = Update-Status -Fresh
        Update-AutoStartSwitch
        Add-LogLine '界面已就绪。'
        if ($s -and -not $s.wifiAlive) {
            Add-LogLine '提示：Wi-Fi（热点）当前不可用 —— 游戏模式暂时开不了，重拨模式和其它按钮照常可用。'
        }
    }
    catch { Write-UiError -Where 'Add_Shown' -Err $_ }
})

$form.Add_FormClosing({
    param($sender, $e)
    if ($script:ReallyExiting) {
        $timer.Stop()
        return
    }
    # 点 X ≠ 退出：收进托盘（管理器继续跑）。要真退出走托盘右键或界面上的「退出」。
    $e.Cancel = $true
    $form.Hide()
    Add-LogLine '窗口已收进托盘（程序还在跑）；退出：右键托盘图标 →「退出」，或界面上的「退出」按钮。'
    if (-not $script:BalloonShown) {
        $script:BalloonShown = $true
        try { $tray.ShowBalloonTip(3000, '还在后台运行', '关掉窗口只是收起界面。退出：右键任务栏托盘图标 → 退出。', 'Info') } catch { }
    }
})

[void]$form.ShowDialog()
