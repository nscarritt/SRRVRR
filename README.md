# SRRVRR

A tiny live CPU / memory / GPU / network dashboard for Windows, in the spirit of
Task Manager's Performance tab. Run it on one machine and watch it from any
browser on your network.

One PowerShell script. Nothing to install.

Current version: **0.4.0**. See the [changelog](CHANGELOG.md) for what changed in each version.

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

A **Storage** card lists every local drive (1 GB or larger) with a usage bar, used/total space and
the health Windows reports for the disk it's on (Healthy / Warning / Unhealthy, from the drive's
own SMART self-monitoring). Bars turn amber at 85% full and red at 95%. Drives are re-checked
every 30 seconds on a separate background thread, so the once-a-second graphs never stall. The
last column shows each drive's live read and write speed ("R 12 MB/s · W 3 MB/s"), updated every
second from Windows' per-drive disk counters.

The header shows how long the server has been up (e.g. "Up 3 days, 4 hours") and an amber
**Restart pending** badge when Windows has installed updates that are waiting for a restart
(checked every 60 seconds via the registry markers Windows Update and the servicing stack set).

For NVIDIA cards, the GPU tile also shows the card's temperature next to its usage, from
`nvidia-smi` (installed with NVIDIA's driver), updated every 5 seconds. It turns amber at 80 °C
and red at 90 °C. AMD and Intel have no built-in equivalent, so their cards show no temperature.

The page follows your system's light/dark theme and works on phones.

## Requirements

- Windows 10/11 or Windows Server with Windows PowerShell 5.1 (built in)
- English-language Windows (performance counter names are localized)
- Any modern browser to view the page

## Quick start

1. Copy these files to the machine you want to watch, all in one folder:
   - `SRRVRR.ps1`
   - `Start SRRVRR.bat`
   - `SRRVRR.config.example.psd1`
2. Copy `SRRVRR.config.example.psd1` to `SRRVRR.config.psd1` and edit it
   (see [Settings](#settings)). Without it, the defaults below are used.
3. Right-click `Start SRRVRR.bat` > **Run as administrator**.
4. Open the address the window shows, e.g. `http://<that-machine>:8099` or
   `http://<its-IP>:8099`, from any browser on your network.

Leave the window open while you want monitoring. Close it (or press Ctrl+C) to stop.

## Settings

All settings live in `SRRVRR.config.psd1`, next to `SRRVRR.ps1`. Restart the
monitor after changing it.

That file is listed in `.gitignore`, so it is never committed to the repository and pulling or
copying a new version of the code never overwrites it. When updating, replace only
`SRRVRR.ps1`, `Start SRRVRR.bat` and `SRRVRR.config.example.psd1`.

| Setting | Default | Values |
|---------|---------|--------|
| `Port` | `8099` | Port the dashboard is served on. The monitor always listens on this machine's own addresses (its name, its network IP and `localhost`). |
| `FirewallScope` | `'LocalSubnet'` | The firewall rule is always set up, since other PCs can't reach the page without it. This chooses who it lets in: `'LocalSubnet'` = devices on the same local network. `'Allowlist'` = only `FirewallAddresses`. `'Blocklist'` = the local network, except `FirewallAddresses`. |
| `FirewallAddresses` | `@()` | Addresses for `Allowlist`/`Blocklist`: single IPs, ranges or subnets, e.g. `@('192.168.1.20', '192.168.1.100-192.168.1.120', '10.0.0.0/24')`. Private addresses only: `192.168.x.x`, `10.x.x.x`, `172.16-31.x.x`, `169.254.x.x`, `127.x.x.x`, IPv6 `fe80::/10` and `fc00::/7`; anything else stops the monitor with a message (but see `AllowPublicAddresses`). |
| `AllowPublicAddresses` | `$false` | **Security risk, at your own risk.** `$true` lets an `Allowlist` also contain specific public (internet) IPs, single addresses only. Read [Security warning: public IP addresses](#security-warning-public-ip-addresses) first. |
| `PreferredGpu` | `''` | The graphics card to show, by its exact name as Windows reports it (dxdiag > Display > Name, or Device Manager > Display adapters), e.g. `'NVIDIA T600'`. Not case-sensitive. `''`, or a name that isn't found, = the GPU with the most video memory. At startup the console shows the card in use and its size (e.g. `NVIDIA T600 · 4 GB`), and lists every GPU's name if `PreferredGpu` isn't found, so you can copy one. |
| `Processes` | all `$true` | One switch per built-in table row, e.g. `@{ Valheim = $true; Plex = $false }`. `$false` hides that row; the table disappears when every row is hidden. |
| `ValheimPort` | `2456` | The Valheim server's game port. Its player count is read from the status query on the next port up. |

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

`SRRVRR.config.example.psd1` has the same settings with comments explaining each one.
Unknown settings are ignored with a warning; an invalid `FirewallScope` value stops the monitor
with a message saying what's allowed.

### Upgrading from an older version

**Renamed from System Monitor to SRRVRR.** The files are now `SRRVRR.ps1`, `Start SRRVRR.bat` and
`SRRVRR.config.example.psd1`, and the firewall rules are named "SRRVRR". On first start the old
"System Monitor" firewall rules are removed automatically, and an existing
`SystemMonitor.config.psd1` is still read (with a note to rename it to `SRRVRR.config.psd1`).

`ListenAddress`, `OpenFirewall` and `GpuFallback` are no longer used: the monitor always listens
on this machine's own addresses, always sets up the firewall rule, and falls back to the GPU with
the most video memory. An old config still works; the monitor just notes that those settings can
be deleted. `PreferredGpu` now needs the card's full name (e.g. `'NVIDIA T600'` rather than
`'T600'`); if it doesn't match, the startup message lists the names to choose from.

### Command-line override

```powershell
.\SRRVRR.ps1 [-Port <number>]
```

`-Port` overrides the config file for that run.

### Firewall rules

The rules are rebuilt on every start to match the current settings:

- `LocalSubnet`, `Allowlist`: one Allow rule, "SRRVRR".
- `Blocklist`: an Allow rule for the local network plus a Block rule, "SRRVRR (blocked)",
  for `FirewallAddresses` (Windows applies Block rules first).

The page has no password, so it is deliberately limited to local networks: every scope only
admits local-network addresses, unless you opt in to `AllowPublicAddresses` (below). To remove
the rules:

```powershell
Remove-NetFirewallRule -DisplayName 'SRRVRR', 'SRRVRR (blocked)'
```

## Security warning: public IP addresses

> **USE AT YOUR OWN RISK.** Setting `AllowPublicAddresses = $true` and listing public IPs in an
> `Allowlist` exposes this monitor to the internet. Do this only if you understand and accept
> the risks below.

SRRVRR was built for trusted home and office networks. It was **not** designed or
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

Under each running process, a quiet detail line says what it's doing:

- **Plex:** active streams and how many are transcoding (re-encoding on the fly, which is what
  loads the GPU) versus direct play, e.g. "2 streams · 1 transcoding". Hover for who is watching
  what. Read every 10 seconds from Plex's local API (`/status/sessions`). The Plex token is read
  from Plex's own settings in the registry of the account Plex runs under; it is never stored in
  the config, printed, or sent to the page.
- **Valheim:** players online, how fast the server answers its status query, and its CPU use in
  whole cores, e.g. "3 players · responding in 4 ms · using 0.9 cores". Hover for player names and
  how long each has been on. Read every 10 seconds with Valve's A2S server query (UDP, on
  `ValheimPort` + 1). Valheim answers that query from its main game loop, so a reply over 250 ms
  turns amber; and since its simulation is mostly one main thread, cores near 1.0 while players
  report lag point at that thread. Per-player ping is not part of the query. The server must run
  with `-public 1`: servers started with `-public 0` or in crossplay mode don't answer the query,
  which shows quietly as "status query off"; a server that stops
  answering after it had been shows in amber.

## Administrator vs. not

- **As administrator:** the page is reachable from other devices on your network, the firewall
  rule is managed, and per-process network works.
- **Not as administrator:** it still runs, but only `http://localhost:<port>` on that machine
  works and per-process network shows "n/a".

## Troubleshooting

- **Page won't load from another PC:** make sure it was started as administrator, and check the
  firewall rule: `Get-NetFirewallRule -DisplayName 'SRRVRR'`.
- **"The process cannot access the file because it is being used by another process":**
  something else is using the port. Pick another `Port`.
- **GPU tile says "... not found, showing ...":** `PreferredGpu` doesn't exactly match any card's
  name. The startup message lists the names Windows reports; copy one into the config.
- **GPU shows N/A:** the machine has no GPU performance counters (e.g. no GPU or a basic display driver).
- **Script won't run (execution policy):** use the `.bat` launcher, or run
  `powershell -ExecutionPolicy Bypass -File .\SRRVRR.ps1`.

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

Copyright 2026 nscarritt. Licensed under the
[PolyForm Noncommercial License 1.0.0](LICENSE)
([official text](https://polyformproject.org/licenses/noncommercial/1.0.0)).

In short (the license text is what counts):

- **Noncommercial use only.** Personal use, hobby projects, research and use by charities,
  schools and public bodies are allowed. Commercial use is not.
- You may share it and changes you make, for noncommercial purposes, keeping the license and the
  `Required Notice` line with it.
- No warranty and no liability; see also the
  [Disclaimer and limitation of liability](#disclaimer-and-limitation-of-liability) above.

Versions 0.1.0 to 0.3.0 were released under the MIT License; copies obtained under those
releases keep their MIT terms. This license applies from the next version on.

Valheim, Plex, NVIDIA, AMD and Intel logos are trademarks of their respective owners and are
used only to identify those products; they are not covered by this license. The CPU, memory,
network, GPU and storage icons are from [Lucide](https://lucide.dev) (ISC license).
