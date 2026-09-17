<#
.SYNOPSIS
把 CampusNetworkUI.ps1 和引擎脚本打进一个单文件 CampusNetwork.exe。

.DESCRIPTION
用 Windows 自带的 csc.exe（.NET Framework 4.8）编译 host.cs，脚本作为**内嵌资源**一起打进 exe：

    csc /target:winexe /win32manifest:app.manifest /resource:<脚本>,scripts.<脚本> ...

本机没有 .NET SDK、没有 PS2EXE、没有 NSIS —— in-box 的 csc.exe 是唯一能完全离线出 exe 的路子。
exe 本身不含业务逻辑，它启动时把脚本解到 %LOCALAPPDATA%\CampusNetworkRedial\scripts 再跑 GUI。

.PARAMETER OutPath
输出路径。默认是仓库根目录下的 CampusNetwork.exe。

.PARAMETER SkipVerify
跳过编译后自检（一般不必要，自检很快）。
#>

[CmdletBinding()]
param(
    [string]$OutPath,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $OutPath) { $OutPath = Join-Path $root 'CampusNetwork.exe' }

# 打进 exe 的脚本。host.cs 是用 "scripts." 前缀扫内嵌资源的，所以这里加文件不用改 host.cs。
$scripts = @(
    'CampusNetworkUI.ps1'
    'Switch-NetworkPath.ps1'
    'Test-CampusExit.ps1'
    'Test-BothExits.ps1'
    'Set-AutoStart.ps1'
    'Redial-UntilCampusReady.ps1'
)

# 图标（app.ico）若在就打进 exe：既当 exe 的文件图标，也解压出来给窗口和托盘用。没有也能编。
$assets = @($scripts)
$iconPath = Join-Path $root 'app.ico'
if (Test-Path -LiteralPath $iconPath) { $assets += 'app.ico' }

function Find-Csc {
    $candidates = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe')
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    throw '找不到 csc.exe（Windows 自带的 .NET Framework 4.x 编译器）。'
}

Write-Output '=== 前置检查 ==='
$csc = Find-Csc
Write-Output ("csc   : {0}" -f $csc)
Write-Output ("        {0}" -f (Get-Item -LiteralPath $csc).VersionInfo.FileVersion)

$missing = @()
foreach ($s in $assets) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $s))) { $missing += $s }
}
$manifest = Join-Path $root 'app.manifest'
if (-not (Test-Path -LiteralPath $manifest)) { $missing += 'app.manifest' }
if (-not (Test-Path -LiteralPath (Join-Path $root 'host.cs'))) { $missing += 'host.cs' }
if ($missing.Count) {
    throw ("缺少源文件，无法编译：{0}" -f ($missing -join ', '))
}

foreach ($s in $assets) {
    $f = Get-Item -LiteralPath (Join-Path $root $s)
    Write-Output ('  {0,-30} {1,8} 字节' -f $s, $f.Length)
}

Write-Output ''
Write-Output '=== 编译 ==='
if (Test-Path -LiteralPath $OutPath) {
    try {
        Remove-Item -LiteralPath $OutPath -Force -ErrorAction Stop
    }
    catch {
        # 常见原因就是"exe 正在运行"：Windows 不让覆盖正在执行的 exe。
        throw ("删不掉旧的 {0} —— 多半是 CampusNetwork.exe 正在运行（或被杀软锁着）。先关掉它再重编。原始错误：{1}" -f $OutPath, $_.Exception.Message)
    }
}

$cscArgs = @(
    '/nologo'
    '/target:winexe'
    '/optimize+'
    '/platform:anycpu'
    '/codepage:65001'                       # host.cs 里有中文，明确按 UTF-8 读
    ('/win32manifest:' + $manifest)
    ('/out:' + $OutPath)
)
if (Test-Path -LiteralPath $iconPath) { $cscArgs += ('/win32icon:' + $iconPath) }
foreach ($s in $assets) {
    $cscArgs += ('/resource:{0},scripts.{1}' -f (Join-Path $root $s), $s)
}
$cscArgs += (Join-Path $root 'host.cs')

Write-Output ('csc {0}' -f ($cscArgs -join ' '))
& $csc @cscArgs
if ($LASTEXITCODE -ne 0) { throw ("编译失败，csc 退出码 {0}" -f $LASTEXITCODE) }

if (-not (Test-Path -LiteralPath $OutPath)) { throw '编译没报错，但输出文件不存在。' }

$exe = Get-Item -LiteralPath $OutPath
Write-Output ''
Write-Output ("=== 产物 ===`n{0}`n{1} 字节 ({2:N1} KB)" -f $exe.FullName, $exe.Length, ($exe.Length / 1KB))

if (-not $SkipVerify) {
    Write-Output ''
    Write-Output '=== 自检 ==='

    # 1) 内嵌资源齐不齐（反射读元数据，不执行 exe）
    $expected = @($assets | ForEach-Object { 'scripts.' + $_ })
    $actual = @([System.Reflection.Assembly]::ReflectionOnlyLoadFrom($OutPath).GetManifestResourceNames())
    $missingRes = @($expected | Where-Object { $actual -notcontains $_ })
    if ($missingRes.Count) {
        throw ('内嵌资源缺失：{0}' -f ($missingRes -join ', '))
    }
    Write-Output ('  内嵌资源 {0}/{1} ✓' -f $actual.Count, $expected.Count)

    # 2) 清单里确实要求管理员（决定"双击只弹一次 UAC"）。RT_MANIFEST 是明文嵌进 PE 的。
    $bytes = [IO.File]::ReadAllBytes($OutPath)
    $ascii = [Text.Encoding]::ASCII.GetString($bytes)
    if ($ascii -notmatch 'requireAdministrator') {
        throw 'exe 里没找到 requireAdministrator 清单 —— 双击不会提权，脚本还得自己弹 UAC。'
    }
    Write-Output '  管理员清单 requireAdministrator ✓'
}

Write-Output ''
Write-Output '好了。双击这个 exe 即可（只弹一次 UAC）。'
Write-Output '脚本会解到 %LOCALAPPDATA%\CampusNetworkRedial\scripts，日志在它的 logs\ 下。'
Write-Output '想手动看/改脚本副本：CampusNetwork.exe -ExtractScripts <目录>'
