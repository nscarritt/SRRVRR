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
| GPU     | Busiest GPU engine (e.g. 3D, video decode), plus dedicated GPU memory in use |
| Network | Receive and send rates across all adapters |

The page follows your system's light/dark theme and works on phones.

## Requirements

- Windows 10/11 or Windows Server with Windows PowerShell 5.1 (built in)
- English-language Windows (performance counter names are localized)
- Any modern browser to view the page

## Quick start

1. Copy `SystemMonitor.ps1` and `Start System Monitor.bat` to the machine you want to watch.
2. Right-click `Start System Monitor.bat` > **Run as administrator**.
3. Open `http://<that-machine>:8099` from any browser on your network
   (or `http://localhost:8099` on the machine itself).

Leave the window open while you want monitoring. Close it (or press Ctrl+C) to stop.

## Options

```powershell
.\SystemMonitor.ps1 [-Port <number>] [-OpenFirewall]
```

| Option          | Default | What it does |
|-----------------|---------|--------------|
| `-Port`         | `8099`  | Port the dashboard is served on |
| `-OpenFirewall` | off     | Adds an inbound Windows Firewall rule named "System Monitor" for the port, limited to your local subnet. The `.bat` launcher passes this for you. |

## Administrator vs. not

- **As administrator:** the page is reachable from other devices on your network.
- **Not as administrator:** it still runs, but only `http://localhost:<port>` on that machine works.

## Troubleshooting

- **Page won't load from another PC:** make sure it was started as administrator, and that the
  "System Monitor" firewall rule exists (`Get-NetFirewallRule -DisplayName 'System Monitor'`).
- **"The process cannot access the file because it is being used by another process":**
  something else is using the port. Pick another with `-Port`.
- **GPU shows N/A:** the machine has no GPU performance counters (e.g. no GPU or a basic display driver).
- **Script won't run (execution policy):** use the `.bat` launcher, or run
  `powershell -ExecutionPolicy Bypass -File .\SystemMonitor.ps1`.

## How it works

A background loop reads Windows performance counters once per second
(`Processor Information`, `Memory`, `Network Interface`, `GPU Engine`, `GPU Adapter Memory`)
and keeps the latest values in memory. A small built-in web server (`HttpListener`) serves
the dashboard page at `/` and the latest readings as JSON at `/stats`, which the page polls.

The page has no authentication, so it is meant for a trusted home or office network only.
To remove the firewall rule later:

```powershell
Remove-NetFirewallRule -DisplayName 'System Monitor'
```
