# 校园网出口检测 + 自动重拨

<a href="https://github.com/Introduce183/campus-network-redial"><img src="https://img.shields.io/badge/o(%3E%E2%96%BD%3C)o%20%E7%BB%99%E6%88%91%E7%82%B9%E4%B8%AAstar%E5%96%B5-e0a587?style=flat-square" alt="o(&gt;▽&lt;)o 给我点个star喵" width="300"></a>

拨号上网时，每次拨号可能分配到不同的出口。好出口一切正常；坏出口会对部分服务限速，导致某些应用加载不出来。

本工具通过探针判断当前出口好坏，并在出口不好时自动重拨，直到拿到好出口。

## 检测原理

用一个在线服务作为探针：好出口能快速连通它的接口，坏出口则会被限速到请求超时。当前探针使用斗鱼直播的接口。

## 环境要求

- Windows，已保存拨号连接的账号密码
- PowerShell 5.1+

## 用法

### 只检测当前出口（不拨号）

```powershell
powershell -ExecutionPolicy Bypass -File .\Test-CampusExit.ps1
```

### 自动重拨直到好出口

最简单的方式：直接双击 `Redial-UntilCampusReady.bat`。它会先自动检测拨号上网电话簿里的宽带名称，再用检测到的名称运行主脚本。

也可以手动在 PowerShell 里运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\Redial-UntilCampusReady.ps1
```

脚本会自动识别拨号连接名；识别不到时默认使用“宽带连接”。也可以手动指定：

```powershell
powershell -ExecutionPolicy Bypass -File .\Redial-UntilCampusReady.ps1 -DialName "校园网"
```

按 `Ctrl+C` 可随时停止。

## 判定逻辑

- 每轮探测多次，全部通过才算一轮通过。
- 两轮探测（间隔确认）都通过，才判定为“好出口”。
- 判定为好出口后脚本停止，并提示“好了喵”（署名 introduce），此时网络可正常使用。

## 参数

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-DialName` | 自动识别 | 拨号连接名（`rasdial` 可查看）|
| `-TestOnly` | 关 | 只测当前网络，不拨号 |
| `-TimeoutSeconds` | 4 | 每次探测超时秒数 |
| `-ProbeCount` | 3 | 每轮探测次数 |
| `-SettleSeconds` | 10 | 拨号后等待多少秒再探测 |
| `-ConfirmIntervalSeconds` | 12 | 两轮确认之间的间隔秒数 |
| `-PauseSeconds` | 8 | 重拨之间的等待秒数 |
| `-MaxAttempts` | 0 | 最大重拨次数，0 表示一直重拨直到成功 |
