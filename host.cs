// 校园网网络管理器 —— exe 宿主（引导器）。
//
// 这个 exe 只做三件事，**不含任何业务逻辑**：
//   1. 把内嵌的 .ps1 脚本解出来（%LOCALAPPDATA%\CampusNetworkRedial\scripts）——每次启动都按内容哈希核对，
//      对不上就重写；解出来的文件设为只读，减少被改动的机会。
//   2. 用 powershell.exe 起 CampusNetworkUI.ps1（无控制台窗口）。
//   3. 支持 -ExtractScripts <dir> 显式导出，方便自己看/调试。
//
// 为什么逻辑留在 PowerShell 里：停放开关、/32 引导、双断言、退避、健康检查判据都是一整轮实机测出来的结论，
// 重写成 C# 等于把那些结论全部重新验证一遍。
//
// 权限：exe 清单（app.manifest）要求管理员，所以**双击只弹一次 UAC**，
// 之后 GUI、引擎、计划任务注册全都在这个提权上下文里跑，不再各自弹框。

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

static class Program
{
    const string AppDirName = "CampusNetworkRedial";
    const string UiScript = "CampusNetworkUI.ps1";
    const string VersionFile = ".version";
    const string ResourcePrefix = "scripts.";
    const int AttachParentProcess = -1;
    const uint MbIconError = 0x00000010;

    // 打进 exe 的资源**不写死**：用 "scripts." 前缀扫一遍就行。
    // 这样以后增删文件（比如加 app.ico）不用改 host.cs，哈希核对也自动覆盖新文件。

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AttachConsole(int dwProcessId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

    static int Main(string[] args)
    {
        try
        {
            if (args.Length > 0 && IsArg(args[0], "-ExtractScripts"))
            {
                string target = (args.Length > 1 && !string.IsNullOrWhiteSpace(args[1]))
                    ? args[1]
                    : DefaultExtractDir();
                Extract(target, true);
                Say("脚本已导出到：" + target + Environment.NewLine +
                    string.Join(Environment.NewLine, ListNames(target)));
                return 0;
            }

            string dir = Extract(DefaultExtractDir(), false);
            return RunUi(Path.Combine(dir, UiScript));
        }
        catch (Exception ex)
        {
            string log = Path.Combine(DefaultExtractDir(), "host-error.log");
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(log));
                File.AppendAllText(log,
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + ex + Environment.NewLine,
                    Encoding.UTF8);
            }
            catch { }

            // 没有控制台时也得让人看见，所以用 MessageBox 而不是 Console。
            MessageBoxW(IntPtr.Zero,
                ex.Message + Environment.NewLine + Environment.NewLine + "详情：" + log,
                "校园网网络管理器：启动失败", MbIconError);
            return 1;
        }
    }

    static bool IsArg(string value, string expected)
    {
        return string.Equals(value, expected, StringComparison.OrdinalIgnoreCase)
            || string.Equals(value, "/" + expected.TrimStart('-'), StringComparison.OrdinalIgnoreCase);
    }

    static string[] ListNames(string dir)
    {
        var lines = new List<string>();
        foreach (string f in Directory.GetFiles(dir))
        {
            lines.Add("  " + f);
        }
        lines.Sort(StringComparer.Ordinal);
        return lines.ToArray();
    }

    static void Say(string text)
    {
        // winexe 子系统没有自己的控制台：借父进程的用（从 cmd/PowerShell 里调用时可读）。
        AttachConsole(AttachParentProcess);
        try
        {
            Console.SetOut(new StreamWriter(Console.OpenStandardOutput()) { AutoFlush = true });
        }
        catch { }
        Console.WriteLine(text);
    }

    static string DefaultExtractDir()
    {
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            AppDirName,
            "scripts");
    }

    // ---------------------------------------------------------------- 解压

    static Dictionary<string, byte[]> ReadEmbeddedScripts()
    {
        Assembly asm = Assembly.GetExecutingAssembly();
        var map = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        foreach (string full in asm.GetManifestResourceNames())
        {
            if (!full.StartsWith(ResourcePrefix, StringComparison.Ordinal))
            {
                continue;
            }
            using (Stream s = asm.GetManifestResourceStream(full))
            {
                if (s == null)
                {
                    continue;
                }
                using (var ms = new MemoryStream())
                {
                    s.CopyTo(ms);
                    map[full.Substring(ResourcePrefix.Length)] = ms.ToArray();
                }
            }
        }
        if (map.Count == 0)
        {
            throw new InvalidOperationException("这个 exe 里一个内嵌资源都没有（重新跑一次 build.ps1）。");
        }
        if (!map.ContainsKey(UiScript))
        {
            throw new InvalidOperationException("内嵌资源里没有界面脚本 " + UiScript + "（重新跑一次 build.ps1）。");
        }
        return map;
    }

    static string HashOf(byte[] data)
    {
        using (SHA256 sha = SHA256.Create())
        {
            byte[] h = sha.ComputeHash(data);
            var sb = new StringBuilder(16);
            for (int i = 0; i < 8; i++)
            {
                sb.Append(h[i].ToString("x2"));
            }
            return sb.ToString();
        }
    }

    static string VersionOf(Dictionary<string, byte[]> scripts)
    {
        var sb = new StringBuilder();
        // 排序后拼：顺序必须稳定，否则同样的内容会算出不同的版本号、每次启动都重解压。
        var names = new List<string>(scripts.Keys);
        names.Sort(StringComparer.Ordinal);
        foreach (string name in names)
        {
            sb.Append(name).Append(':').Append(HashOf(scripts[name])).Append(';');
        }
        byte[] raw = Encoding.UTF8.GetBytes(sb.ToString());
        using (SHA256 sha = SHA256.Create())
        {
            byte[] h = sha.ComputeHash(raw);
            var hex = new StringBuilder(16);
            for (int i = 0; i < 8; i++)
            {
                hex.Append(h[i].ToString("x2"));
            }
            return hex.ToString();
        }
    }

    static bool IsUpToDate(string dir, Dictionary<string, byte[]> scripts)
    {
        foreach (KeyValuePair<string, byte[]> kv in scripts)
        {
            string path = Path.Combine(dir, kv.Key);
            if (!File.Exists(path))
            {
                return false;
            }
            try
            {
                if (HashOf(File.ReadAllBytes(path)) != HashOf(kv.Value))
                {
                    return false;
                }
            }
            catch
            {
                return false;
            }
        }
        return true;
    }

    static string Extract(string dir, bool force)
    {
        Dictionary<string, byte[]> scripts = ReadEmbeddedScripts();

        // 两个实例同时启动时别互相踩（跨进程互斥体）。
        using (var mutex = new Mutex(false, @"Local\CampusNetworkRedialExtract"))
        {
            bool held = false;
            try
            {
                try { held = mutex.WaitOne(TimeSpan.FromSeconds(30)); }
                catch (AbandonedMutexException) { held = true; }
                if (!held)
                {
                    throw new InvalidOperationException("另一个实例正在准备脚本，稍后再试。");
                }

                Directory.CreateDirectory(dir);
                if (!force && IsUpToDate(dir, scripts))
                {
                    return dir;
                }

                foreach (KeyValuePair<string, byte[]> kv in scripts)
                {
                    string path = Path.Combine(dir, kv.Key);
                    if (File.Exists(path))
                    {
                        try { File.SetAttributes(path, FileAttributes.Normal); } catch { }
                    }
                    File.WriteAllBytes(path, kv.Value);
                    try { File.SetAttributes(path, FileAttributes.ReadOnly); } catch { }
                }
                File.WriteAllText(Path.Combine(dir, VersionFile), VersionOf(scripts), Encoding.ASCII);
                return dir;
            }
            finally
            {
                if (held) { mutex.ReleaseMutex(); }
            }
        }
    }

    // ---------------------------------------------------------------- 起界面

    static int RunUi(string scriptPath)
    {
        if (!File.Exists(scriptPath))
        {
            throw new FileNotFoundException("界面脚本不见了（解压失败）：" + scriptPath);
        }

        var psi = new ProcessStartInfo("powershell.exe")
        {
            Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + scriptPath + "\"",
            UseShellExecute = false,
            CreateNoWindow = true,          // 不闪控制台
            WorkingDirectory = Path.GetDirectoryName(scriptPath),
        };

        using (Process p = Process.Start(psi))
        {
            if (p == null)
            {
                throw new InvalidOperationException("没能启动 powershell.exe。");
            }
            p.WaitForExit();
            return p.ExitCode;
        }
    }
}
