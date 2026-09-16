# 校园网出口检测 + 自动重拨

<a href="https://github.com/Introduce183/campus-network-redial"><img src="https://img.shields.io/badge/o(%3E%E2%96%BD%3C)o%20%E7%BB%99%E6%88%91%E7%82%B9%E4%B8%AAstar%E5%96%B5-e0a587?style=flat-square" alt="o(&gt;▽&lt;)o 给我点个star喵" width="300"></a>

拨号上网时，每次拨号可能分配到不同的出口。好出口一切正常；坏出口会对部分服务限速，导致某些应用加载不出来。

本工具通过探针判断当前出口好坏，并在出口不好时自动重拨，直到拿到好出口。

`Switch-NetworkPath.ps1` 则在同一套探针之上做**常驻主备管理**：拨号作主用、Wi-Fi 作保底，两者自动切换，保证任何时候都至少有一条可用出口。**找出口的整个过程你都在 Wi-Fi 上，只有确认可用的出口才会被提为主用。**

## 图形界面：一个 exe 搞定（主推用法）

不想记命令行就用 `CampusNetwork.exe` —— 后面那些工具都在一个窗口里。编译好的在 [Releases](https://github.com/Introduce183/campus-network-redial/releases/latest)，也可以自己用 `build.ps1` 编。双击它**只弹一次 UAC**（exe 清单要求管理员，之后 GUI、引擎、计划任务注册都在这个提权上下文里跑）。

窗口分三块：**实时状态**、**两个模式**（标签页）、**日志 + 两个共用按钮**。

**两个模式（互斥 —— 都要动拨号，同时开会互抢 `rasdial`，所以一个在跑另一个就置灰）**

| 模式 | 背后 | 说明 |
| --- | --- | --- |
| **正常重拨模式** | `Redial-UntilCampusReady.ps1` | 一直换出口直到确认好出口。运行方式三选一：**普通重拨** / **只测当前出口**（`-TestOnly`，不拨号，当体检用）/ **高速模式**（`-HighBandwidthMode`，重拨到西电测速超 150 Mbps）。输出**实时**进日志区，完整输出另存 `logs\redial-*.out.txt` |
| **游戏模式** | `Switch-NetworkPath.ps1`（常驻管理器） | 停放 → 确认好出口转主用 → 变坏立刻退回 Wi-Fi。硬前提是**先连上热点**，没连上按钮置灰并提示；面板上还有它自己的**开机自启** |

共用按钮：**恢复拨号优先**（等价 `-RestoreDialPriority`）、**测一轮双出口**（两个出口各测一次 + 出口源地址确认，追加到 `logs\exit-compare.log`）。

状态面板每秒读一次 `logs\status.json`（纯文件读，不会一直起新进程）：当前承载、健康已持续多久、电话簿开关、**拨号是否真的握着默认路由**、Wi-Fi 保底是否可用。

两个刻意的设计：**停管理器是写一个 `logs\stop.req` 让它优雅退出**（直接杀进程会跳过还原逻辑，电话簿会留在停放态）；**关窗口不会停任何模式**（要停就点按钮）。

### exe 的来路（改了脚本必须重编）

`build.ps1` 用 Windows 自带的 `csc.exe` 编译 `host.cs`，脚本作为**内嵌资源**打进同一个 exe：

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1     # 产出 CampusNetwork.exe
```

启动时把脚本解到 `%LOCALAPPDATA%\CampusNetworkRedial\scripts`：**每次启动按内容哈希核对**，对不上就重写，解出来的文件设为只读。日志（含 `redial-*.out.txt`）也在那个目录下，**不是**仓库里的 `logs\`。想单独导出一份副本看/改：`CampusNetwork.exe -ExtractScripts D:\临时目录`。

## 检测原理

用一个在线服务作为探针：好出口能快速连通它的接口，坏出口则会被限速到请求超时。当前探针使用斗鱼直播的接口。

## 环境要求

- Windows，已保存拨号连接的账号密码
- PowerShell 5.1+
- **网络管理器需要管理员权限**（要改电话簿里的拨号条目开关、加删路由）；`Test-CampusExit.ps1` 和 `Redial-UntilCampusReady.ps1` 不需要

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

### 高速模式：重拨直到带宽达标

如果只关心出口带宽，可以用 `-HighBandwidthMode`：脚本会重拨并测速，直到西电 LibreSpeed 下载测速超过 150 Mbps 才停下。

```powershell
powershell -ExecutionPolicy Bypass -File .\Redial-UntilCampusReady.ps1 -HighBandwidthMode
```

该模式与 `-TestOnly` 互斥，不能同时使用。

### 设置开机自启

双击 `Set-AutoStart.bat`（会弹一次 UAC）。菜单里两个自启条目互相独立，可以分别开关：

- 自动重拨脚本（前台窗口，拿到好出口后停下）—— 走 HKCU Run 键
- 网络管理器（登录后后台常驻，无窗口）—— 走**最高权限计划任务**

两者不要同时开，它们会互相抢 `rasdial`。建议只开网络管理器。

管理器之所以用计划任务而不是 Run 键：它必须提权才能改电话簿和路由，而 Run 键没法让进程提权，用 Run 键启会每次登录弹一次 UAC。

计划任务的动作参数是：

```text
-NoProfile -ExecutionPolicy Bypass -File "E:\campus-network-redial\Switch-NetworkPath.ps1"
```

**不带** `-KeepParkedOnExit`（和 `Switch-NetworkPath.bat` 一致）：管理器退出时会把电话簿里的停放开关还原成 `1` 并重连，也就是让**拨号重新成为默认网关（拨号优先级最高）**。

想让管理器退出后一直待在 Wi-Fi 上，就给这两处都加上 `-KeepParkedOnExit`（改 `Set-AutoStart.ps1` 里的 `$managerTaskArgs`，然后重开一次自启）。

### 常驻网络管理器：Wi-Fi 保底 + 拨号主用

> ### ⚠️ 启用前必读
>
> **1. 开启这个脚本之前，必须先连上热点（Wi-Fi）。**
> 脚本的原理是"把拨号停放到 Wi-Fi 旁边、流量跑在 Wi-Fi 上、拨号只做后台候选"，所以 Wi-Fi 是它的硬前提。
> 热点没连上时它会**拒绝启动并退出，不做任何改动** —— 因为那种情况下停放等于把流量丢进黑洞
> （拨号让出默认路由，而 Wi-Fi 给不出路由），会变成彻底没有网络出口。
>
> **2. 此脚本只保证一直都有可用网络，可能会在校园网与热点之间切换，不保证游戏时的稳定性。**

> 图形界面里那个 **游戏模式** 就是这件事 —— 同一套逻辑，换了个名字（见最前面那节）。

双击 `Switch-NetworkPath.bat`（会弹一次 UAC）。它会常驻运行：

1. **首次运行会装一个开关**：把拨号条目在电话簿里的 `IpPrioritizeRemote` 改成 `0`，也就是关掉拨号的"在远程网络上使用默认网关"。拨号仍然正常连接（拿到 IP、链路可用），但不再抢默认路由 —— 于是**每次拨上都是"停放态"，流量留在 Wi-Fi 上**。
2. 在 Wi-Fi 承载的前提下验证这个新出口（三轮确认，见下）。
3. 只有全部通过、并且确认探针确实是从拨号出口发出去的，才**加一条指向拨号的默认路由**把它提为主用。
4. 成为主用后每 3 秒做健康检查，**只要有一轮不通过就立刻**删掉那条默认路由（流量立刻回到 Wi-Fi，拨号 IP 都不变），再换一个出口重拨。
5. 退出时会把电话簿里的开关还原成 `1` 并重连，让机器回到"拨号当默认网关"的常态。

一句话：**你几乎不会察觉到它在换出口。**

查看当前走哪条出口（只读，不拨号、不断线、不需要提权）：

```powershell
powershell -ExecutionPolicy Bypass -File .\Switch-NetworkPath.ps1 -Status
```

运行日志在 `logs\network-path.log`（超过 1 MB 自动滚成 `.1`）。按 `Ctrl+C` 停止。

同一时刻只允许一个实例在跑，重复启动会被互斥体挡掉。

> ### ⚠️ 退出后电话簿开关会怎样
>
> `Switch-NetworkPath.bat`（以及开机自启的计划任务）**不带** `-KeepParkedOnExit`，
> 所以**管理器正常退出时会把停放开关还原成 `1` 并重连 —— 拨号重新成为默认网关，也就是拨号优先级最高。**
> （退出时如果拨号正好断在"换出口"的中间，会补拨一次；上一次晋升留下的那条默认路由也会被清掉。）
>
> 但要注意一个例外：**如果管理器是被"硬杀"的**（直接关窗口 / 任务管理器结束进程），`finally` 里的还原逻辑
> **不会执行**，电话簿会留在停放态 `0`。此时拨号仍能连上但不抢默认路由，机器会一直待在 Wi-Fi 上。
> 这种情况下用下面的一行命令恢复。

### 恢复成"拨号优先"

停放开关是电话簿里的 `IpPrioritizeRemote`，`0` = 拨号不抢默认路由，`1` = 拨号当默认网关。

**一行恢复（推荐）** —— 把开关写回 `1` 并重连，然后打印状态退出（会弹一次 UAC）：

```powershell
powershell -ExecutionPolicy Bypass -File .\Switch-NetworkPath.ps1 -RestoreDialPriority
```

想确认当前值，随时跑 `-Status`，第一段就是：

   ```text
   --- 电话簿（停放开关）---
     IpPrioritizeRemote = 0   （0 = 拨号不抢默认路由 / 停放态；1 = 拨号当默认网关）
   ```

其它可选做法：跑一次管理器然后 `Ctrl+C`（退出时也会还原），或者在宽带连接属性里手动改回来。

停放在 `0` 期间拨号**仍然可以正常拨上**（`rasdial` 能连、能拿到 IP），只是它不承载你的流量 —— 管理器就是靠这一点在后台验证新出口的。

## 判定逻辑

- 每轮探测多次，全部通过才算一轮通过。
- 三轮探测（两段间隔确认）都通过，才判定为“好出口”；第三轮之前等待更久，避免前两轮通过后出口仍不稳定。
- 判定为好出口后，脚本提示“好了喵”（署名 introduce），并询问是否继续测速或者重新拨号：输入 `Y` 继续重新探测，探测失败会自动重新拨号，成功则继续提示不退出；输入其它任意键退出。

## 参数

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-DialName` | 自动识别 | 拨号连接名（`rasdial` 可查看）|
| `-TestOnly` | 关 | 只测当前网络，不拨号 |
| `-HighBandwidthMode` | 关 | 高速模式：重拨直到测速超过 150 Mbps（不能与 `-TestOnly` 同时使用）|
| `-TimeoutSeconds` | 4 | 每次探测超时秒数 |
| `-ProbeCount` | 3 | 每轮探测次数 |
| `-SettleSeconds` | 3 | 拨号后等待多少秒再探测 |
| `-ConfirmIntervalSeconds` | 12 | 第 1、2 轮确认之间的间隔秒数 |
| `-ThirdIntervalSeconds` | 30 | 第 2、3 轮确认之间的间隔秒数 |
| `-PauseSeconds` | 2 | 重拨之间的等待秒数 |
| `-MaxAttempts` | 0 | 最大重拨次数，0 表示一直重拨直到成功 |

## 网络管理器（`Switch-NetworkPath.ps1`）

### 主备怎么切

靠一个电话簿开关 + 运行时加删一条路由。三段都经过实机验证。

**1. 停放（一次性安装，需提权）** —— 把拨号条目的 `IpPrioritizeRemote` 从 `1` 改成 `0`：

```
[校园网-1]
IpPrioritizeRemote=0     ← "在远程网络上使用默认网关" 关掉
```

拨号照常连接，但**不安装默认路由**。RAS 只在连接时读这个值，所以改完要重连一次；但那是一次性的，不在循环里。由此得到"停放态"：**拨号连着，流量走 Wi-Fi。**

**2. 晋升 / 降级（运行时，需提权，不重连）**

| 动作 | 操作 | 效果 |
| --- | --- | --- |
| 晋升 | `New-NetRoute` 加一条指向拨号的默认路由 | 流量回到拨号，**拨号 IP 不变** |
| 降级 | `Remove-NetRoute` 删掉那条 | 流量回到 Wi-Fi，**拨号 IP 不变** |

路由的 `RouteMetric` 取到让拨号的有效跃点（`RouteMetric + 接口跃点`）小于 Wi-Fi 的即可。

那条晋升路由是**运行时产物**，跟电话簿开关无关 —— 它只存在于 `ActiveStore`，不会自己消失。所以两处都会清它：
**退出时**（包括 `-KeepParkedOnExit`，否则"保留停放"名不副实：电话簿写着停放、拨号却还在抢默认路由）和**下次启动时**
（只要发现拨号还握着默认路由，就重连一次把接口连同残留路由一起重建）。这也是"开着拨号再启动脚本会报错"那个 bug 的修法。

**3. 探测停放中的拨号出口（运行时，需提权）** —— 拨号没有默认路由时探针会跟着走 Wi-Fi，所以探测前给 canary 的 IPv4 装 `/32` 主机路由指向拨号接口，探完删掉。`/32` 是最具体前缀，必然胜过默认路由。

### 为什么不用"改跃点"来切

实测过，都不可靠：

| 手段 | 实测结果 |
| --- | --- |
| `Set-NetIPInterface` 改拨号跃点 | 表上有效跃点确实变了（WLAN 5 vs 拨号 6001），**实际流量仍在拨号** |
| 电话簿里 `IpInterfaceMetric=6000` | 重连后接口跃点确实是 6000、表上 WLAN 赢，**实际流量仍在拨号** |
| 事后 `Remove-NetRoute` 删拨号默认路由 | 对外访问直接不通，连绑 Wi-Fi 源也救不回来 |
| `SkipAsSource=true` 于拨号地址 | 连拨号自己当主用都不通 |

原因：`IpPrioritizeRemote=1` 时，RAS 那条默认路由**不受跃点影响**。所以要走另一个开关。

**顺带一个坑**：`Find-NetRoute` **不能**用来判断"当前走哪条出口" —— 实测它对跃点变化不敏感，会一直返回原来那条。管理器只把它当预选，最终结论一律用 `curl -w '%{local_ip}'` 读实际出口源地址来确认。

### 验证与降级

- **验证三轮 + 一道闸**：快判 → 隔 12 秒 → 确认 1/2 → 隔 30 秒 → 确认 2/2 → 出口源地址确认（`curl` 读到的源地址必须等于拨号接口地址），全部通过才晋升。判据沿用 `Test-CampusExit.ps1`，脚本本身未做任何改动。
- **健康检查**：主用状态下**每 3 秒**探测一轮，每轮 **2 个探针**（两个 canary 主机各一票、等权），**只要有一个挂就判不健康并立刻切回 Wi-Fi**（`-HealthPassThreshold` 默认 0 = 全部通过；`-FailThreshold` 默认 1 = 一轮不过就切，不再要求连续失败两次）。
  **第一个探针一挂就收手**，不再等后面的探针超时 —— 这是给探针脚本加了 `-StopOnFailure` 开关实现的（默认关，见下）。
- **健康检查用更短的探测超时**（`-HealthTimeoutSeconds` 默认 2 秒，晋升验证仍用 `-TimeoutSeconds`=4 秒）：实测健康出口的单个探针只要 **150–460ms**，2 秒已是 4–13 倍余量。
  于是从出口变坏到流量回到 Wi-Fi 最坏约 **6 秒**（3s 轮询 + 2s 探测 + 删路由），原来是 12–15 秒。
- **`Test-CampusExit.ps1` 新增 `-StopOnFailure`（可选，默认关）**：开了就"一个探针挂即收手"。默认关是为了让**既有的调用方行为逐字不变** —— `Redial-UntilCampusReady.ps1` 用的还是原来的"跑满 `-Count` 次"，不受影响。只有管理器的健康检查会主动开启它。
  主用态下拨号自己握着默认路由，canary 天然走拨号，所以这一轮**不做 `/32` 引导、也不做出口源地址确认** —— 省掉每轮 18 次路由表增删。停放态（验证出口时）才用 `/32` 引导。
- **健康检查出错怎么办**：检查本身抛异常（DNS 挂了、CIM 报错之类）会记一条 ERROR，**按不健康处理**（退回 Wi-Fi 保底），并且**不会把管理器进程带走**。
- **健康检查怎么记日志**：健康时**不写日志文件**，只在控制台原地刷一行（不滚动）：

  ```text
  [23:01:48] 健康 · 已持续 12分34秒
  ```

  真的坏了才写正式日志，并带上**此前已健康多久**：
  另外把 `-FailThreshold` 调大于 1 时，恢复也会记一条并重新计时（默认为 1，一轮不过就直接降级，所以看不到"已恢复"）。

  ```text
  健康检查：未通过 —— 通过 0/1（本轮 2 个探针，首个失败即中止）（直连探测）。此前已健康 12分34秒。
  健康检查：已恢复 —— Campus exit probe passed 2 of 2（直连探测）。本段从 23:02:05 重新计时。
  ```

  所以 `logs\network-path.log` 里只剩真正有意义的事件，3 秒一轮也不会把它刷爆。
- **降级不需要断开拨号** —— 只删掉那条默认路由，流量立刻回 Wi-Fi，你的 IP 都不变。只有确实要换出口时才断开重拨，而那时流量已经在 Wi-Fi 上了。
- **保底检查**：降级前会确认 Wi-Fi 活着（网卡 Up + 有默认路由 + 网关 ping 通）。Wi-Fi 不可用时会记一条 ERROR 并立刻重拨，把无网窗口压到最短。
- **退避只针对"拨号失败"**：`rasdial` 返回非 0 时退避 2→4→8…→60 秒封顶。"出口不好"不算失败，固定停顿后重拨继续换出口。

### 参数

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-DialName` | 自动识别 | 拨号连接名 |
| `-WifiName` | 自动识别 | 无线网卡名（按 802.11 介质自动找）|
| `-TimeoutSeconds` | 4 | 单次探测超时秒数（晋升验证用）|
| `-ProbeCount` | 2 | 每轮探测次数。两个 canary 主机各一次，**别设成 3**：探针是 `$uris[(i-1) % 2]` 轮转的，设 3 会让第一个主机拿到两票、第二个只拿一票，投票权重变成 2:1（已实测确认过这个坑）|
| `-SettleSeconds` | 3 | 拨上后等待几秒再验证 |
| `-ConfirmIntervalSeconds` | 12 | 快判与第 2 轮之间的间隔秒数 |
| `-ThirdIntervalSeconds` | 30 | 第 2、3 轮之间的间隔秒数 |
| `-HealthIntervalSeconds` | 3 | 健康检查周期（最小 1 秒）|
| `-HealthPassThreshold` | 0 | 一轮里通过几个探针才算健康。**0 = 全部通过**（配合 `-ProbeCount 2` 就等于"挂一个就切"）。想放宽就传正整数 |
| `-HealthTimeoutSeconds` | 2 | 健康检查的单个探针超时（晋升验证仍用 `-TimeoutSeconds`）|
| `-FailThreshold` | 1 | 连续几轮不健康才降级；默认 1 = 一轮不过就切回 Wi-Fi |
| `-PauseSeconds` | 2 | 坏出口后重新拨号前的停顿 |
| `-MaxDialBackoffSeconds` | 60 | 拨号失败时的退避上限 |
| `-KeepParkedOnExit` | 关 | 退出时**不**还原电话簿开关（保持停放=一直待在 Wi-Fi）；同时会把上次晋升留下的拨号默认路由删掉，否则名义停放、实际还在用拨号。`Switch-NetworkPath.bat` 和计划任务都**不带**它，所以默认是退出即恢复拨号优先 |
| `-RestoreDialPriority` | — | 一次性恢复：把电话簿开关写回 `1`、重连、打印状态后退出（硬杀之后的恢复入口，免提权可跑但会自提权）|
| `-LogPath` | `logs\network-path.log` | 日志路径（`status.json` / `stop.req` 也跟着放同一目录）|
| `-Status` | — | 只打印当前状态，不进循环（免提权可跑）|
| `-StatusJson` | — | 同上，但输出 JSON（给图形界面 / 其它脚本读，免提权可跑）|

### 首次运行会改什么

- `C:\ProgramData\Microsoft\Network\Connections\Pbk\rasphone.pbk`：把 `[校园网-1]` 段的 `IpPrioritizeRemote` 改成 `0`。
  改之前会**自动备份**到 `logs\rasphone.pbk.bak`，写完会做完整性自检（段落头 / 关键行 / 换行符），
  自检不过立刻回滚 —— 因为把这个文件写坏会让 RAS 报 623「找不到电话簿项目」。
- 退出时会改回 `1` 并重连，让拨号重新当默认网关（除非加 `-KeepParkedOnExit`）。被硬杀时不会还原，用 `-RestoreDialPriority` 恢复。

### 给图形界面 / 其它脚本用的接口

管理器在跑的时候会维护两个文件（跟日志同目录，默认 `logs\`），图形界面就是靠它们工作的：

| 文件 | 谁写 | 用途 |
| --- | --- | --- |
| `logs\status.json` | 管理器（每轮检查后重写）| 机器可读状态：当前承载、健康已持续秒数、最近一次检查结果、电话簿开关、**拨号是否握着默认路由**、Wi-Fi 保底是否可用 |
| `logs\stop.req` | 外部（图形界面，或你自己）| **优雅停止信号**：管理器每轮看到它就正常退出并走完整的还原流程。之所以不用"直接杀进程"，是因为杀进程会跳过还原 —— 电话簿会留在停放态、晋升那条路由也会留下 |

只想问一句状态、不想起管理器（免提权）：

```powershell
powershell -ExecutionPolicy Bypass -File .\Switch-NetworkPath.ps1 -StatusJson
```

## 实测记录（2026-09-11）

留档备查，都是在本机实测得到的：

- **Wi-Fi 保底确实可用**：断开拨号后 `taobao`/`bilibili` 均 200、`generate_204` 返回 204，源地址都是 Wi-Fi 的 `172.29.81.43`。
- **停放 + 加/删默认路由的切换已验证**（全部用"改动后才解析的新域名"+ `curl` 源地址判定）：

  ```text
  停放态   拨号连着(10.194.175.183)、无默认路由
    ubuntu.com   code=301  src=172.29.81.43   Wi-Fi
    centos.org   code=200  src=172.29.81.43   Wi-Fi
  晋升：加默认路由 Route=4 → 有效 29 < Wi-Fi 30
    nodejs.org   code=307  src=10.194.175.183  拨号
    gitlab.com   code=308  src=10.194.175.183  拨号
    拨号 IP 仍是 10.194.175.183（没重连）
  降级：删掉那条路由
    atlassian.com code=200 src=172.29.81.43   Wi-Fi
    salesforce.com code=302 src=172.29.81.43  Wi-Fi
  ```

  两个方向都反复验证过一遍，拨号 IP 始终不变。
- **出口好坏是按协议族分的**：某次观测到拨号出口 IPv4 被限速（canary 两个主机都 4 秒超时），但 IPv6 是好的（`apiv2` 走 CERNET 0.14 秒返回 200）。所以探针钉死在 IPv4 是有意义的 —— 混着测会把坏的 v4 出口误判成好出口。
