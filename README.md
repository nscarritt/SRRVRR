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
| GPU     | Busiest engine (e.g. 3D, video decode) of one chosen GPU, plus its dedicated memory in use. The tile shows the card maker's logo (NVIDIA, AMD or Intel) |
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
4. Open the address the window shows, e.g. `http://<that-machine>:8099` or
   `http://<its-IP>:8099`, from any browser on your network.

Leave the window open while you want monitoring. Close it (or press Ctrl+C) to stop.

## Settings

All settings live in `SystemMonitor.config.psd1`, next to `SystemMonitor.ps1`. Restart the
monitor after changing it.

That file is listed in `.gitignore`, so it is never committed to the repository and pulling or
copying a new version of the code never overwrites it. When updating, replace only
`SystemMonitor.ps1`, `Start System Monitor.bat` and `SystemMonitor.config.example.psd1`.

| Setting | Default | Values |
|---------|---------|--------|
| `Port` | `8099` | Port the dashboard is served on. The monitor always listens on this machine's own addresses (its name, its network IP and `localhost`). |
| `FirewallScope` | `'LocalSubnet'` | The firewall rule is always set up, since other PCs can't reach the page without it. This chooses who it lets in: `'LocalSubnet'` = devices on the same local network. `'Allowlist'` = only `FirewallAddresses`. `'Blocklist'` = the local network, except `FirewallAddresses`. |
| `FirewallAddresses` | `@()` | Addresses for `Allowlist`/`Blocklist`: single IPs, ranges or subnets, e.g. `@('192.168.1.20', '192.168.1.100-192.168.1.120', '10.0.0.0/24')`. Private addresses only: `192.168.x.x`, `10.x.x.x`, `172.16-31.x.x`, `169.254.x.x`, `127.x.x.x`, IPv6 `fe80::/10` and `fc00::/7`; anything else stops the monitor with a message (but see `AllowPublicAddresses`). |
| `AllowPublicAddresses` | `$false` | **Security risk, at your own risk.** `$true` lets an `Allowlist` also contain specific public (internet) IPs, single addresses only. Read [Security warning: public IP addresses](#security-warning-public-ip-addresses) first. |
| `PreferredGpu` | `''` | The graphics card to show, by its exact name as Windows reports it (dxdiag > Display > Name, or Device Manager > Display adapters), e.g. `'NVIDIA T600'`. Not case-sensitive. `''`, or a name that isn't found, = the GPU with the most video memory. At startup the console shows the card in use and its size (e.g. `NVIDIA T600 · 4 GB`), and lists every GPU's name if `PreferredGpu` isn't found, so you can copy one. |
| `Processes` | all `$true` | One switch per built-in table row, e.g. `@{ Valheim = $true; Plex = $false }`. `$false` hides that row; the table disappears when every row is hidden. |

Example:

```powershell
@{
    Port              = 8099
    FirewallScope     = 'LocalSubnet'
    FirewallAddresses = @()
    PreferredGpu      = 'NVIDIA T600'
    Processes         = @{ Valheim = $true; Plex = $true }
}
```

`SystemMonitor.config.example.psd1` has the same settings with comments explaining each one.
Unknown settings are ignored with a warning; an invalid `FirewallScope` value stops the monitor
with a message saying what's allowed.

### Upgrading from an older version

`ListenAddress`, `OpenFirewall` and `GpuFallback` are no longer used: the monitor always listens
on this machine's own addresses, always sets up the firewall rule, and falls back to the GPU with
the most video memory. An old config still works; the monitor just notes that those settings can
be deleted. `PreferredGpu` now needs the card's full name (e.g. `'NVIDIA T600'` rather than
`'T600'`); if it doesn't match, the startup message lists the names to choose from.

### Command-line override

```powershell
.\SystemMonitor.ps1 [-Port <number>]
```

`-Port` overrides the config file for that run.

### Firewall rules

The rules are rebuilt on every start to match the current settings:

- `LocalSubnet`, `Allowlist`: one Allow rule, "System Monitor".
- `Blocklist`: an Allow rule for the local network plus a Block rule, "System Monitor (blocked)",
  for `FirewallAddresses` (Windows applies Block rules first).

The page has no password, so it is deliberately limited to local networks: every scope only
admits local-network addresses, unless you opt in to `AllowPublicAddresses` (below). To remove
the rules:

```powershell
Remove-NetFirewallRule -DisplayName 'System Monitor', 'System Monitor (blocked)'
```

## Security warning: public IP addresses

> **USE AT YOUR OWN RISK.** Setting `AllowPublicAddresses = $true` and listing public IPs in an
> `Allowlist` exposes this monitor to the internet. Do this only if you understand and accept
> the risks below.

System Monitor was built for trusted home and office networks. It was **not** designed or
security-tested for the internet. If you allow public IP addresses:

- **No password.** Anyone who connects from an allowed IP sees the page. There is no login.
- **No encryption.** The page is served over plain HTTP. Anything between you and the server
  (public Wi-Fi, your mobile carrier, ISPs along the way) can read it.
- **IP addresses are a weak lock.** Many people can share one public IP (mobile carriers,
  hotels, offices, carrier-grade NAT), and home IPs change: the address you allowed today may
  belong to a stranger tomorrow.
- **It reveals information.** Your computer's name, which programs are running (e.g. your game
  or media server), and patterns of activity, such as when you're streaming, playing, or away.
- **More attack surface.** Opening a port means internet scanners will find it. Any flaw in this
  script, PowerShell, or Windows' web server component (`HttpListener`/`http.sys`) becomes
  reachable from the internet.
- **You must also forward the port on your router.** That is a change you make outside this
  tool, and it is your responsibility to undo it.

Safeguards in this tool: public addresses are refused unless you opt in, only in an
`Allowlist`, only as **single** IPs (no ranges, subnets or "any"), and every start prints a
warning listing the public IPs that are let in.

**Safer alternative:** use a VPN to reach your home network instead of opening a port, for
example [Tailscale](https://tailscale.com), [WireGuard](https://www.wireguard.com), or your
router's built-in VPN. The page then stays on your local network.

### Disclaimer and limitation of liability

This software is provided **"as is"**, without warranty of any kind, express or implied,
including but not limited to the warranties of merchantability, fitness for a particular purpose
and non-infringement. In no event shall the authors or copyright holders be liable for any
claim, damages or other liability, whether in an action of contract, tort or otherwise, arising
from, out of or in connection with the software or the use or other dealings in the software,
including, without limitation, any exposure of your systems or information resulting from
enabling `AllowPublicAddresses`, opening firewall ports, or forwarding ports on your router.
**By enabling `AllowPublicAddresses`, you accept full responsibility for the consequences.**

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
- **GPU tile says "... not found, showing ...":** `PreferredGpu` doesn't exactly match any card's
  name. The startup message lists the names Windows reports; copy one into the config.
- **GPU shows N/A:** the machine has no GPU performance counters (e.g. no GPU or a basic display driver).
- **Script won't run (execution policy):** use the `.bat` launcher, or run
  `powershell -ExecutionPolicy Bypass -File .\SystemMonitor.ps1`.

## How it works

A background loop reads Windows performance counters once per second
(`Processor Information`, `Memory`, `Network Interface`, `GPU Engine`, `GPU Adapter Memory`,
`Process`) and keeps the latest values in memory. A small built-in web server (`HttpListener`)
serves the dashboard page at `/` and the latest readings as JSON at `/stats`, which the page polls.
The GPU is picked through Windows' DirectX adapter list in the registry (the same names dxdiag
shows), which uses the same adapter IDs as the GPU counters and also gives the card's vendor ID
for the logo: NVIDIA (`10DE`), AMD (`1002`/`1022`) or Intel (`8086`); anything else gets a
plain GPU icon.

Logos and icons are built into the script, so the page needs no internet access: Valheim emblem
(valheimgame.com), Plex chevron (Plex Media Server), NVIDIA eye mark (nvidia.com), AMD arrow
(amd.com), Intel wordmark (Intel's 2020 logo), and CPU/RAM/network/GPU icons from
[Lucide](https://lucide.dev) (ISC license).

## License

[MIT](LICENSE) © 2026 nscarritt. Provided "as is", without warranty of any kind; see the
[Disclaimer and limitation of liability](#disclaimer-and-limitation-of-liability) above.
Valheim, Plex, NVIDIA, AMD and Intel logos are trademarks of their respective owners and are used only to
identify those products; they are not covered by this license.
