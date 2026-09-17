<#
.SYNOPSIS
把一张 PNG 转成多尺寸 app.ico（给 exe、窗口和托盘用）。

.DESCRIPTION
不依赖任何外部工具：ICO 容器 + 每帧的 DIB（BITMAPINFOHEADER + 32bpp BGRA 像素 + AND 掩码）
全部手写。**刻意不用"PNG 压缩帧"** —— 那种写法 Windows 只在 256x256 上老实支持，
而且 .NET 的 System.Drawing.Icon 读它会报错；DIB 帧到处都能认。

用法：
    powershell -ExecutionPolicy Bypass -File .\make-icon.ps1                     # 默认读 xidian-logo.png 写 app.ico
    powershell -ExecutionPolicy Bypass -File .\make-icon.ps1 -Source 图.png -Out app.ico
#>

[CmdletBinding()]
param(
    [string]$Source,
    [string]$Out
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $Source) { $Source = Join-Path $root 'xidian-logo.png' }
if (-not $Out) { $Out = Join-Path $root 'app.ico' }

if (-not (Test-Path -LiteralPath $Source)) { throw "找不到源图片：$Source" }

Add-Type -AssemblyName System.Drawing

$sizes = @(16, 24, 32, 48, 64, 128, 256)

function Get-DibBytes {
    # 一帧 DIB：40 字节头 + 自下而上的 32bpp BGRA 像素 + AND 掩码（32bpp 时全 0 即可）
    param([System.Drawing.Bitmap]$Bmp)

    $w = $Bmp.Width
    $h = $Bmp.Height
    $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
    $data = $Bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $stride = $data.Stride
        $raw = New-Object byte[] ($stride * $h)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $raw, 0, $raw.Length)
    }
    finally { $Bmp.UnlockBits($data) }

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    try {
        $bw.Write([uint32]40)                 # biSize
        $bw.Write([int32]$w)                  # biWidth
        $bw.Write([int32]($h * 2))            # biHeight = 2×（XOR + AND）
        $bw.Write([uint16]1)                  # biPlanes
        $bw.Write([uint16]32)                 # biBitCount
        $bw.Write([uint32]0)                  # biCompression = BI_RGB
        $bw.Write([int32]($w * $h * 4))       # biSizeImage
        $bw.Write([int32]0); $bw.Write([int32]0)
        $bw.Write([uint32]0); $bw.Write([uint32]0)
        for ($y = $h - 1; $y -ge 0; $y--) { $bw.Write($raw, $y * $stride, $w * 4) }
        $maskRowBytes = [int][Math]::Ceiling($w / 32.0) * 4
        $bw.Write((New-Object byte[] ($maskRowBytes * $h)), 0, ($maskRowBytes * $h))
        $bw.Flush()
        return $ms.ToArray()
    }
    finally { $bw.Dispose(); $ms.Dispose() }
}

Write-Output ("源图：{0}" -f $Source)
$src = [System.Drawing.Image]::FromFile($Source)
try {
    Write-Output ("     尺寸 {0}×{1}   像素格式 {2}" -f $src.Width, $src.Height, $src.PixelFormat)

    $frames = @()
    foreach ($s in $sizes) {
        $bmp = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.Clear([System.Drawing.Color]::Transparent)
            $g.DrawImage($src, 0, 0, $s, $s)
        }
        finally { $g.Dispose() }
        $frames += , @{ Size = $s; Bytes = (Get-DibBytes -Bmp $bmp) }
        $bmp.Dispose()
    }
}
finally { $src.Dispose() }

# ---- 组装 ICO：6 字节头 + 每帧 16 字节目录项 + 各帧数据
$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)
try {
    $bw.Write([uint16]0)                      # reserved
    $bw.Write([uint16]1)                      # type = icon
    $bw.Write([uint16]$frames.Count)
    $offset = 6 + 16 * $frames.Count
    foreach ($f in $frames) {
        $dim = if ($f.Size -ge 256) { 0 } else { $f.Size }
        $bw.Write([byte]$dim); $bw.Write([byte]$dim)
        $bw.Write([byte]0); $bw.Write([byte]0)          # 调色板数 / 保留
        $bw.Write([uint16]1); $bw.Write([uint16]32)     # planes / bpp
        $bw.Write([uint32]$f.Bytes.Length)
        $bw.Write([uint32]$offset)
        $offset += $f.Bytes.Length
    }
    foreach ($f in $frames) { $bw.Write($f.Bytes, 0, $f.Bytes.Length) }
    $bw.Flush()
    [IO.File]::WriteAllBytes($Out, $ms.ToArray())
}
finally { $bw.Dispose(); $ms.Dispose() }

# ---- 自检：能被 .NET 当图标读出来，且各尺寸都在
$ico = New-Object System.Drawing.Icon($Out)
try {
    Write-Output ("写出：{0}   {1} 字节" -f $Out, (Get-Item -LiteralPath $Out).Length)
    foreach ($s in $sizes) {
        $one = New-Object System.Drawing.Icon($Out, (New-Object System.Drawing.Size($s, $s)))
        Write-Output ("     取 {0,3}×{0,-3} → 实得 {1}×{2}" -f $s, $one.Width, $one.Height)
        $one.Dispose()
    }
    Write-Output ("默认尺寸 {0}×{1} ✓" -f $ico.Width, $ico.Height)
}
finally { $ico.Dispose() }
