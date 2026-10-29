# Test helper: sends Ctrl+C to the console of process -TargetId (attaches to its console, then generates the event),
# the way a person pressing Ctrl+C in SRRVRR's window would.
param([int]$TargetId)
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CtrlC {
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GenerateConsoleCtrlEvent(uint ev, uint group);
    public static string Send(uint pid) {
        FreeConsole();
        if (!AttachConsole(pid)) { return "attach failed " + Marshal.GetLastWin32Error(); }
        SetConsoleCtrlHandler(IntPtr.Zero, true);   // this process ignores the Ctrl+C it sends
        bool ok = GenerateConsoleCtrlEvent(0, 0);
        System.Threading.Thread.Sleep(500);
        FreeConsole();
        return ok ? "sent" : "generate failed " + Marshal.GetLastWin32Error();
    }
}
'@
[CtrlC]::Send([uint32]$TargetId)
