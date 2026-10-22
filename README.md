# System Monitor

A tiny live CPU / memory / GPU / network dashboard for Windows, in the spirit of
Task Manager's Performance tab. Run it on one machine and watch it from any
browser on your network.

One PowerShell script. Nothing to install.

## What it shows

Updated every second, each with a 60-second graph:

| Card    | Details |
|---------|---------|
| CPU     | Overall utilization (the same number Task Manager shows) |
| Memory  | % used and GB used / total |
| GPU     | Busiest engine (e.g. 3D, video decode) of one chosen GPU, plus its dedicated memory in use |
| Network | Receive and send rates across all adapters |

Below the graphs, a **Processes** table shows CPU, memory, GPU and network up/down for
specific programs (a Valheim dedicated server and Plex), or "Offline" when they aren't running.

The page follows your system's light/dark theme and works on phones.

## Requirements

- Windows 10/11 or Windows Server with Windows PowerShell 5.1 (built in)
- English-language Windows (performance counter names are localized)
- Any modern browser to view the page

## Quick start

1. Copy these files to the machine you want to watch, all in one folder:
   - `SystemMonitor.ps1`
   - `Start System Monitor.bat`
   - `SystemMonitor.config.example.psd1`
2. Copy `SystemMonitor.config.example.psd1` to `SystemMonitor.config.psd1` and edit it
   (see [Settings](#settings)). Without it, the defaults below are used.
3. Right-click `Start System Monitor.bat` > **Run as administrator**.
4. Open `http://<that-machine>:8099` from any browser on your network.

Leave the window open while you want monitoring. Close it (or press Ctrl+C) to stop.

## Settings

All settings live in `SystemMonitor.config.psd1`, next to `SystemMonitor.ps1`. Restart the
monitor after changing it.

That file is listed in `.gitignore`, so it is never committed to the repository and pulling or
copying a new version of the code never overwrites it. When updating, replace only
`SystemMonitor.ps1`, `Start System Monitor.bat` and `SystemMonitor.config.example.psd1`.

| Setting | Default | Values |
|---------|---------|--------|
| `Port` | `8099` | Port the dashboard is served on. |
| `ListenAddress` | `'+'` | `'+'` = every address on this machine. An IP address of this machine (e.g. `'192.168.1.50'`) = only that address. `'localhost'` = only this machine can open the page. |
| `OpenFirewall` | `$true` | `$true` = on every start, set up a Windows Firewall rule named "System Monitor" for `Port` (needs administrator). `$false` = leave the firewall alone. |
| `FirewallScope` | `'LocalSubnet'` | Who the firewall lets in: `'LocalSubnet'` = devices on the same local network. `'Allowlist'` = only `FirewallAddresses`. `'Blocklist'` = the local network, except `FirewallAddresses`. There is no option to open the page to the internet. |
| `FirewallAddresses` | `@()` | Addresses for `Allowlist`/`Blocklist`: single IPs, ranges or subnets, e.g. `@('192.168.1.20', '192.168.1.100-192.168.1.120', '10.0.0.0/24')`. Private addresses only: `192.168.x.x`, `10.x.x.x`, `172.16-31.x.x`, `169.254.x.x`, `127.x.x.x`, IPv6 `fe80::/10` and `fc00::/7`; anything else stops the monitor with a message. |
| `PreferredGpu` | `''` | Part of a graphics card's name as shown in Device Manager > Display adapters, e.g. `'T600'`. `''` = skip and use `GpuFallback`. |
| `GpuFallback` | `'Dedicated'` | GPU to show when `PreferredGpu` is empty or not found: `'Dedicated'` = the graphics card (the GPU with the most video memory). `'Integrated'` = the processor's built-in graphics (the least). `'All'` = add up every GPU. |
| `Processes` | all `$true` | One switch per built-in table row, e.g. `@{ Valheim = $true; Plex = $false }`. `$false` hides that row; the table disappears when every row is hidden. |

Example:

```powershell
@{
    Port              = 8099
    ListenAddress     = '+'
    OpenFirewall      = $true
    FirewallScope     = 'LocalSubnet'
    FirewallAddresses = @()
    PreferredGpu      = 'T600'
    GpuFallback       = 'Dedicated'
    Processes         = @{ Valheim = $true; Plex = $true }
}
```

`SystemMonitor.config.example.psd1` has the same settings with comments explaining each one.
Unknown settings are ignored with a warning; invalid `FirewallScope` or `GpuFallback` values
stop the monitor with a message saying what's allowed.

### Command-line overrides

```powershell
.\SystemMonitor.ps1 [-Port <number>] [-OpenFirewall]
```

`-Port` and `-OpenFirewall` override the config file for that run.

### Firewall rules

With `OpenFirewall = $true`, the rules are rebuilt on every start to match the current settings:

- `LocalSubnet`, `Allowlist`: one Allow rule, "System Monitor".
- `Blocklist`: an Allow rule for the local network plus a Block rule, "System Monitor (blocked)",
  for `FirewallAddresses` (Windows applies Block rules first).

The page has no password, so it is deliberately limited to local networks: every scope only
admits local-network addresses. Don't forward the port on your router. To remove the rules:

```powershell
Remove-NetFirewallRule -DisplayName 'System Monitor', 'System Monitor (blocked)'
```

## Processes table

Each row adds up every process matching that program, including helpers (for Plex: Plex
Transcoder and friends). Numbers are calculated the way Task Manager does: CPU is a share of all
cores, memory is private working set as a share of total RAM, and GPU is the busiest engine on
the chosen GPU. Per-process network comes from Windows' kernel network events (the same source
Resource Monitor uses) and needs the monitor to run as administrator; otherwise it shows "n/a".

The built-in rows are Valheim (`valheim_server.exe`) and Plex (`Plex Media Server.exe`); hide
either with the `Processes` setting.

## Administrator vs. not

- **As administrator:** the page is reachable from other devices on your network, the firewall
  rule is managed, and per-process network works.
- **Not as administrator:** it still runs, but only `http://localhost:<port>` on that machine
  works and per-process network shows "n/a".

## Troubleshooting

- **Page won't load from another PC:** make sure it was started as administrator, and check the
  firewall rule: `Get-NetFirewallRule -DisplayName 'System Monitor'`.
- **"The process cannot access the file because it is being used by another process":**
  something else is using the port. Pick another `Port`.
- **GPU tile says "... not found, showing ...":** `PreferredGpu` doesn't match any card's name;
  check Device Manager > Display adapters.
- **GPU shows N/A:** the machine has no GPU performance counters (e.g. no GPU or a basic display driver).
- **Script won't run (execution policy):** use the `.bat` launcher, or run
  `powershell -ExecutionPolicy Bypass -File .\SystemMonitor.ps1`.

## How it works

A background loop reads Windows performance counters once per second
(`Processor Information`, `Memory`, `Network Interface`, `GPU Engine`, `GPU Adapter Memory`,
`Process`) and keeps the latest values in memory. A small built-in web server (`HttpListener`)
serves the dashboard page at `/` and the latest readings as JSON at `/stats`, which the page polls.
The GPU is picked through Windows' DirectX adapter list in the registry, which uses the same
adapter IDs as the GPU counters.

Logos and icons are built into the script, so the page needs no internet access: Valheim emblem
(valheimgame.com), Plex chevron (Plex Media Server), NVIDIA eye mark (nvidia.com), and CPU/RAM/network
icons from [Lucide](https://lucide.dev) (ISC license).
