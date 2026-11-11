
# SRRVRR

![SRRVRR dashboard: CPU, memory, GPU and network graphs, a Processes table with Valheim and Plex activity, and a Storage card with drive health and read/write speed](docs/screenshot.png)

*A live SRRVRR dashboard. Private share names are blurred.*

A tiny live CPU / memory / GPU / network dashboard for Windows, in the spirit of
Task Manager's Performance tab. Run it on one machine and watch it from any
browser on your network.

A PowerShell script and its modules. Nothing to install.

Current version: **0.7.0**. See the [changelog](CHANGELOG.md) for what changed in each version.

## Contents

- [What it shows](#what-it-shows)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Settings](#settings)
  - [Data folder and logs](#data-folder-and-logs)
  - [Upgrading from an older version](#upgrading-from-an-older-version)
  - [CPU and memory temperatures](#cpu-and-memory-temperatures)
  - [Command-line override](#command-line-override)
  - [Firewall rules](#firewall-rules)
- [Security warning: public IP addresses](#security-warning-public-ip-addresses)
  - [Disclaimer and limitation of liability](#disclaimer-and-limitation-of-liability)
- [Processes table](#processes-table)
- [Alerts](#alerts)
- [Administrator vs. not](#administrator-vs-not)
- [Running SRRVRR at boot](#running-srrvrr-at-boot)
- [Troubleshooting](#troubleshooting)
- [How it works](#how-it-works)
- [Checks and tests](#checks-and-tests)
- [License](#license)

## What it shows

Updated every second, each with a graph of the last 60 seconds or, with the **15 min** button at the
top, the last 15 minutes (each browser remembers its choice). SRRVRR keeps those 15 minutes itself, so
a page you open, or one that comes back after losing its connection, starts with full graphs. A
second with no reading (SRRVRR stopped, or the page lost touch) shows as a gap in the line.

| Card    | Details |
|---------|---------|
| CPU     | Overall utilization (the same number Task Manager shows), and the processor's name (e.g. "Intel Core i7-13700K"). The tile shows the maker's logo (Intel or AMD) |
| Memory  | % used and GB used / total, and the memory's maker and type (e.g. "G.Skill DDR5"; "Mixed" when sticks come from different makers). The tile shows the maker's logo for Samsung, SK hynix, Micron (and its Crucial brand), Kingston, Corsair, G.Skill and ADATA. Hover for each stick's slot, part number, size and the speed it runs at now |
| GPU     | Busiest engine (e.g. 3D, video decode) of one chosen GPU, plus its dedicated memory in use. The tile shows the card maker's logo (NVIDIA, AMD or Intel) |
| Network | Receive and send rates across all adapters |

Below the graphs, a **Processes** table shows CPU, memory, GPU and network up/down for
specific programs (a Valheim dedicated server and Plex), or "Offline" when they aren't running.

A **Storage** card lists every local drive (1 GB or larger) with a usage bar, used/total space and
the health Windows reports for the disk it's on (Healthy / Warning / Unhealthy, from the drive's
own SMART self-monitoring). Bars turn amber at 85% full and red at 95%. Drives are re-checked
every 30 seconds on a separate background thread, so the once-a-second graphs never stall. The
last column shows each drive's live read and write speed in fixed-width cells, in bytes per second
scaled from B/s to GB/s, updated every second from Windows' per-drive disk counters. Each value is
colored by how close it is to the drive's maximum speed: amber at 70%, red at 90%. Windows doesn't
report a drive's maximum, so SRRVRR uses the typical ceiling for its connection and media type
(NVMe SSD ~3,500 MB/s, SATA SSD ~550 MB/s, hard drive ~200 MB/s, USB ~400 MB/s, otherwise
~500 MB/s), raised to the fastest speed actually seen on that drive if it ever goes faster.

A **Transfers** card answers "why is it slow?" for the file shares. Every 5 seconds it names the server resource
closest to its limit while the shares are moving at least 1 MB/s: the network link (the busiest adapter, as a
percent of its link speed), the share's drive (how busy the drive behind a busy share is, with its queue) or the
CPU, such as "Bottleneck: the network link, 94% of 1 Gb/s". When nothing reaches `BottleneckPercent` (80 by
default) it says "Not the server: the client or the path to it", and "Idle" below 1 MB/s. The three numbers are
always shown in small print, and a new name has to come up in two readings in a row before it replaces the old
one, so it doesn't flicker. The numbers are averages over the 5 seconds. Below that, a table lists every share with traffic or open files (its drive, read and write
speed, open files, busiest first), and a graph shows the shares' total read and write speed with the same **60 s**
and **15 min** buttons. It uses the file server's own counters, so it needs no administrator. A copy to the
server's own address never touches the network link, so the link stays low then and the drive is named.
The header shows how long the server has been up (e.g. "Up 3 days, 4 hours") and an amber
**Restart pending** badge when Windows has installed updates that are waiting for a restart
(checked every 60 seconds via the registry markers Windows Update and the servicing stack set).

For NVIDIA cards, the GPU tile also shows the card's temperature next to its usage, from
`nvidia-smi` (installed with NVIDIA's driver), updated every 5 seconds. It turns amber at 80 °C
and red at 90 °C. AMD and Intel have no built-in equivalent, so their cards show no temperature.

The CPU and Memory tiles show a temperature the same way, updated every 5 seconds, once
[temperature sensors are set up](#cpu-and-memory-temperatures):

- **CPU:** the package temperature, the overall reading the processor reports for itself (AMD
  calls it Tctl). An average across cores could hide one hot core. Amber at 80 °C, red at 90 °C;
  most current desktop processors throttle at 95–105 °C. Hover for each core.
- **Memory:** the hottest stick, read from each stick's own sensor, since one overheating stick is
  what causes errors. Amber at 70 °C, red at 80 °C; memory is specified to 85 °C. Hover for each
  stick. DDR5 sticks have a sensor; most DDR4 sticks don't, and then the tile shows a gray
  **No sensor** (hover names the sticks).

When temperatures can't be read (not set up, not running as administrator, or the sensors don't
answer), the tiles show an amber **Temp n/a**; hover for the reason.

**PCs and folders** (administrator only): the Transfers card lists each PC connected to the shares by name, account, read and write speed and open files, with a mark while it writes. A PC is known by its address, so list the PCs you recognize in `NamedPCs` (with fixed addresses); a PC not listed shows its address in amber, with one warning when it connects (`unknown-pc`) and a flag with a banner when it first writes (`unknown-pc-write`), which also record the account. A row opens to the PC's busiest folders, up to 10: the share, the folder below it (3 levels, 120 characters) and how many files are open there, those open for writing marked. SRRVRR never keeps file names: each is dropped as soon as the open files are read, and never reaches the page, /stats or a log. `TransferFolders = $false` keeps only counts. With more than 5,000 open files the card says so and uses the first 5,000.

The page follows your system's light/dark theme and works on phones.

## Requirements

- Windows 10/11 or Windows Server with Windows PowerShell 5.1 (built in), in any display language
- Any modern browser to view the page

**Language support.** Windows translates performance-counter names into its display language,
which breaks tools that look counters up by name with `Get-Counter`. SRRVRR doesn't use it: it
reads counters through .NET, which resolves the English names on every language edition of
Windows, and its other checks (drive health, firewall, registry) don't depend on the language.
The page and console text are in English. It has been tested on English Windows only; if
something doesn't show up on another language, please open an issue.

## Quick start

1. Copy these files and folders to the machine you want to watch, all in one folder:
   - `SRRVRR.ps1`, and the `modules` and `web` folders next to it
   - `Start SRRVRR.bat`
   - `SRRVRR.config.example.psd1`
   - `Install Temperature Sensors.bat` and `Install-TemperatureSensors.ps1` (optional, for CPU
     and memory temperatures)
   - `Stop SRRVRR.bat` (optional, to stop it cleanly)
2. Copy `SRRVRR.config.example.psd1` to `SRRVRR.config.psd1` and edit it
   (see [Settings](#settings)). Without it, the defaults below are used.
3. Optional: double-click `Install Temperature Sensors.bat` once (see
   [CPU and memory temperatures](#cpu-and-memory-temperatures)).
4. Double-click `Start SRRVRR.bat` and click **Yes** on the administrator prompt. Say **No** to
   run it without administrator (see [Administrator vs. not](#administrator-vs-not)).
5. Open the address the window shows, e.g. `http://<that-machine>:8099` or
   `http://<its-IP>:8099`, from any browser on your network.

Leave the window open while you want monitoring. To stop it, press Ctrl+C in the window, or
double-click **`Stop SRRVRR.bat`**, which stops the SRRVRR in its own folder (a test copy in another
folder isn't touched): it signals SRRVRR to save and close, ends it if it hasn't closed after 10 seconds,
closes its window, and says what happened. When SRRVRR was started as administrator, it asks for
administrator too, since only administrator can signal it then. It runs `SRRVRR.ps1 -Stop`, which you
can also run yourself. Closing the window is a hard stop: it skips the save, so up to 5 minutes of
history and the last log line can be lost.

### CPU and memory temperatures

Windows has no built-in way to read the processor's or memory's temperature, so SRRVRR uses two
free components, which `Install-TemperatureSensors.ps1` downloads and sets up:

- **[LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor)'s sensor
  library** (MPL-2.0), copied to `lib\LibreHardwareMonitor` next to `SRRVRR.ps1`. Only the
  library and the files it needs are kept, not the app.
- **The [PawnIO](https://github.com/namazso/PawnIO.Setup) driver**, signed by its author, which the library uses to
  read the sensors. It replaces the old WinRing0 driver that antivirus software flags.

Close SRRVRR, double-click **`Install Temperature Sensors.bat`**, and click **Yes** on the
administrator prompt. The window stays open at the end so you can read what happened. It runs
`Install-TemperatureSensors.ps1`, which you can also run yourself from an administrator
PowerShell window. Both downloads are pinned to one version and checked against a known
SHA-256 hash, and the PawnIO installer's signature is checked too; anything that doesn't match is
refused. At the end it reads the temperatures once, so you can see they work. Then start SRRVRR
again. Running it again is safe: it replaces the library and installs PawnIO only when it's
missing or older. To remove it all: delete the `lib` folder, and uninstall PawnIO from
**Settings > Apps**.

## Settings

All settings live in `SRRVRR.config.psd1`, next to `SRRVRR.ps1`. Restart the
monitor after changing it.

That file is listed in `.gitignore`, so it is never committed to the repository and pulling or
copying a new version of the code never overwrites it.

When updating, replace the code folders and files and nothing else. Stop SRRVRR first, delete the old
`modules` and `web` folders and copy in the new ones whole (so no old file is left behind), then
replace `SRRVRR.ps1`, `Start SRRVRR.bat`, `Stop SRRVRR.bat`, `SRRVRR.config.example.psd1`,
`Install Temperature Sensors.bat`, `Install-TemperatureSensors.ps1`, `README.md`, `CHANGELOG.md`,
`SECURITY.md` and `LICENSE`. Never replace your `SRRVRR.config.psd1`, or the `state`, `logs` and
`lib` folders: they hold your settings, your data and the temperature sensor library.

| Setting | Default | Values |
|---------|---------|--------|
| `Port` | `8099` | Port the dashboard is served on. The monitor always listens on this machine's own addresses (its name, its network IP and `localhost`). |
| `FirewallScope` | `'LocalSubnet'` | The firewall rule is always set up, since other PCs can't reach the page without it. This chooses who it lets in: `'LocalSubnet'` = devices on the same local network. `'Allowlist'` = only `FirewallAddresses`. `'Blocklist'` = the local network, except `FirewallAddresses`. |
| `FirewallAddresses` | `@()` | Addresses for `Allowlist`/`Blocklist`: single IPs, ranges or subnets, e.g. `@('192.168.1.20', '192.168.1.100-192.168.1.120', '10.0.0.0/24')`. Private addresses only: `192.168.x.x`, `10.x.x.x`, `172.16-31.x.x`, `169.254.x.x`, `127.x.x.x`, IPv6 `fe80::/10` and `fc00::/7`; anything else stops the monitor with a message (but see `AllowPublicAddresses`). |
| `AllowPublicAddresses` | `$false` | **Security risk, at your own risk.** `$true` lets an `Allowlist` also contain specific public (internet) IPs, single addresses only. Read [Security warning: public IP addresses](#security-warning-public-ip-addresses) first. |
| `PreferredGpu` | `''` | The graphics card to show, by its exact name as Windows reports it (dxdiag > Display > Name, or Device Manager > Display adapters), e.g. `'NVIDIA T600'`. Not case-sensitive. `''`, or a name that isn't found, = the GPU with the most video memory. At startup the console shows the card in use and its size (e.g. `NVIDIA T600 · 4 GB`), and lists every GPU's name if `PreferredGpu` isn't found, so you can copy one. |
| `Processes` | all `$true` | One switch per built-in table row, e.g. `@{ Valheim = $true; Plex = $false }`. `$false` hides that row; the table disappears when every row is hidden. |
| `ValheimPort` | `2456` | The Valheim server's game port. Its player count is read from the status query on the next port up. |
| `BurstFiles` | `500` | How many files one PC must open, while writing, within `BurstWindowSeconds` for SRRVRR to flag a write burst: a whole number from 50 to 100000. See [Alerts](#alerts). |
| `BurstWindowSeconds` | `60` | The window, in seconds, in which a PC must open `BurstFiles` files to count as a write burst: a whole number from 10 to 600. |
| `BurstQuietMinutes` | `5` | How many minutes a PC must stay below the burst threshold for its write burst to end: a whole number from 1 to 60. Bursts closer together than this are one burst. |
| `DataPath` | `''` | Where SRRVRR keeps its `state` and `logs` folders. `''` = SRRVRR's own folder; or a full local folder path with a drive letter, e.g. `'D:\SRRVRR'`. See [Data folder and logs](#data-folder-and-logs). |
| `LogRetentionDays` | `31` | How many days of logs to keep, 7 to 366. |
| `MaintenanceHours` | `2` | How long the Maintenance checkbox stays on, in hours (0.25 up to `MaintenanceMaxHours`). |
| `MaintenanceMaxHours` | `8` | The longest Maintenance can stay on, in hours (1 to 24). |
| `NamedPCs` | `@()` | PCs you recognize: up to 32 entries like `@{ Name = 'Desk PC'; Addresses = @('192.0.2.10') }`. `Name` is 1 to 40 printable characters, different from the others (capitals don't count); `Addresses` are 1 to 8 single IPv4 or IPv6 addresses (no ranges, subnets, names or loopback), each in one entry only; any other key is an error. Any PC not listed is unknown. Give the PCs fixed addresses. |
| `TransferFolders` | `$true` | `$true` shows each PC's busiest folders on the Transfers card; `$false` keeps only counts, on the page and in the log. |
| `DriveWarnPercent` | `85` | The percent of a drive that is used when its Storage bar turns amber and a "filling" banner shows, 50 to 99 (below `DriveFullPercent`). |
| `DriveFullPercent` | `95` | The percent used when the bar turns red and the drive is flagged as almost full, 50 to 99. A drive has to fall 2 points below a threshold before its level goes back down. |
| `BottleneckPercent` | `80` | The percent of its limit at which the Transfers card names the network link, the share's drive or the CPU as the bottleneck, a whole number from 50 to 99. Below it the card says "Not the server". |

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
Unknown settings are ignored with a warning; an invalid setting stops the monitor with one message
saying what's allowed (exit code 2).

### Data folder and logs

SRRVRR keeps its data in two folders under `DataPath` (by default its own folder): `state` and `logs`.
It creates those two, never `DataPath` itself.

- **The log**, `logs\srrvrr-YYYY-MM-DD.log`, one file per day: every startup step, settings problems,
  errors from the background readers (each written when it appears or changes, and at most once a
  minute), crashes with their details, and a last line saying why SRRVRR stopped, e.g.
  `stopped: requested (exit 0)`. Each day's file stops growing at 20 MB.
- **The event log**, `logs\events-YYYY-MM-DD.jsonl`, one JSON object per line: warnings and flags (a
  service offline or back, a status query that stopped answering, drive health, the data folder),
  Windows waiting to restart, Maintenance on and off with the address that asked, and every start and
  stop with its reason. Player names, Plex users and devices, and titles never reach it, only counts.
  Each day's file stops growing at 20 MB, except for flags.
- **Old logs** (both kinds) are removed once they're older than `LogRetentionDays`, after the start and
  once a day. Only files directly in `logs` with those exact names are touched; the newest 7 days are
  always kept, and nothing is removed if the clock looks wrong.
- **Maintenance**, `state\maintenance.json`, so a restart in the middle of maintenance doesn't set off
  alerts.
- **The graph history**, `state\history.json`: the last 15 minutes of CPU, memory, GPU and network
  readings (numbers only, about 50 KB), saved every 5 minutes and when SRRVRR stops cleanly. At the
  start it's used if its newest reading is under 15 minutes old. A damaged file, one over 2 MB or one
  from a newer version is renamed `history.json.bad` and history starts empty; nothing else breaks.
- **If `DataPath` is missing or can't be written**, at start or later, SRRVRR uses its own folder until
  the next restart and logs a flag saying so. The Storage card keeps watching the drive that holds
  `DataPath`, even a USB drive, and shows it as Missing when it's gone.
- **It refuses to start** (exit code 3) if the data folder is shared on the network, is on a network
  drive, or is already used by another copy of SRRVRR. That includes a folder on a drive you share as
  a whole (a share of `E:\` covers everything on E:), and a drive root with a shared folder below it.
  Windows' own hidden drive shares (`C$` and the like) don't count. Pick a folder no share covers.
- **When run as administrator**, it makes sure only SYSTEM and Administrators can change `state` and
  `logs`; everyone who could read them before still can.

Exit codes, for anything that starts SRRVRR: 0 a clean stop, 2 a settings error, 3 a refusal to start,
anything else a crash.

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

Found a security problem? Please report it privately, as described in the
[security policy](SECURITY.md), rather than in a public issue.

**Safer alternative:** use a VPN to reach your home network instead of opening a port, or your
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
  what, on which device, and how it's played. Read every 10 seconds from Plex's local API (`/status/sessions`). The Plex token is read
  from Plex's own settings in the registry of the account Plex runs under; it is never stored in
  the config, printed, or sent to the page. If Plex isn't running yet (for example, it starts
  after SRRVRR at boot), SRRVRR looks again every minute until it finds the token.
- **Valheim:** players online, how fast the server answers its status query, and its CPU use in
  whole cores, e.g. "3 players · responding in 4 ms · using 0.9 cores". Hover for player names and
  how long each has been on. Read every 10 seconds with Valve's A2S server query (UDP, on
  `ValheimPort` + 1). Valheim answers that query from its main game loop, so a reply over 250 ms
  turns amber; and since its simulation is mostly one main thread, cores near 1.0 while players
  report lag point at that thread. Per-player ping is not part of the query. The server must run
  with `-public 1`: servers started with `-public 0` or in crossplay mode don't answer the query,
  which shows quietly as "status query off"; a server that stops
  answering after it had been shows in amber.

## Alerts

When something happens on the server, a banner slides down from the top of the page. It closes
by itself after 60 seconds on screen (alerts that arrive while the tab is in the background wait
until you come back), or click × to close it. The last line of each banner is the time it
happened, e.g. "7:42 PM". Times everywhere on the page (banners, the Flagged list, Maintenance)
use one 12-hour format in the browser's own time zone.

- **Valheim:** a player joined or left, e.g. "Ivar joined Valheim · 2 players online". Names
  appear when the server reports them; otherwise "A player joined". Checked every 10 seconds,
  with the player count.

Plex streams don't raise alerts (short episodes made them constant). The Plex row in Processes
still shows the stream count, and its hover lists who's watching what, on which device, and how.

There are banners too when Valheim or Plex goes offline or comes back, when one stops answering
its status query, when a drive's health changes or the data drive goes missing, when SRRVRR falls
back to its own folder or finds the data folder shared, and when it can't save the graph history.

**Write bursts.** A PC that opens a great many files on a share while writing to it (a program
rewriting a share's files, say) raises a "Write burst from <PC>" banner, and the burst is logged as
a `write-burst` flag with its files, bytes and shares, and the account it used and up to 5 folders
when the server runs as administrator. Without administrator the PC is "a PC (needs
administrator)". A burst is `BurstFiles` files opened within `BurstWindowSeconds` seconds, counting
only seconds in which that PC was also writing; it ends once the PC has stayed below that for
`BurstQuietMinutes` minutes (a second rise sooner than that is the same burst), and a
`write-burst-ended` flag with the duration is logged then. A burst still going when SRRVRR stops
cleanly is ended with the reason "stopped". The log holds folders and counts, never file names.

**Accounts and addresses in the log.** The four transfer events (`unknown-pc`, `unknown-pc-write`, `write-burst`
and `write-burst-ended`) record the Windows account the PC used and its address, as evidence of who wrote what. No
other event records a person's name (a Plex stream event never keeps the viewer). So the event logs under `logs\`
and `/events` name your accounts and your PCs' addresses: **never paste a raw log or `/events` output into a public
issue.** To share what the Transfers card sees, run `tools\Export-TransferSample.ps1` as administrator: it writes a
sample with the names, addresses, accounts and paths replaced.
**Sound:** click **Sound off** in the header to turn on a soft ding with each alert (you hear a
sample). Browsers only play sound after you've clicked or tapped the page, so after a reload the
button says "Sound on: tap to allow" until you click or tap anywhere on the page. The choice is remembered in each
browser.

Alerts are decided on the server, so they're caught with no page open, every open page shows the
same ones, and what happened before a page opened never pops up. Browsers check less often in
background tabs, so an alert there can be up to a minute late; if more than 50 arrive while a tab
sleeps, it says so once instead of showing them all.

**Maintenance:** tick **Maintenance** in the header before working on the server. For the next
`MaintenanceHours` (2 by default) no page shows banners or dings; the header says "Maintenance until
3:30 PM" in each browser's own time, in every browser at once, and it survives a restart. Events are
still logged, marked as during maintenance. Untick it to end it early. Any device that can open the
page can tick it; each change is logged with its address, and one address can change it at most once
every 10 seconds and 60 times a day.

**Flagged:** the Flagged card lists the logged events of the last 31 days (or `LogRetentionDays`, if
fewer), newest first.

## Administrator vs. not

- **As administrator:** the page is reachable from other devices on your network, the firewall
  rule is managed, and per-process network and CPU/memory temperatures work.
- **Not as administrator:** it still runs, but only `http://localhost:<port>` on that machine
  works, per-process network shows "n/a", and the CPU and memory temperatures show "Temp n/a".
  The Transfers card says "PCs and folders need administrator": it reads the SMB session and open-file lists with administrator only.

## Running SRRVRR at boot

For anyone who starts SRRVRR from a boot launcher or a scheduled task, this is what SRRVRR promises.

**How to start it.** The entry script is always `SRRVRR.ps1`, in the folder you installed it to; it loads
`modules` and `web` from that same folder only. Start it as administrator with
`powershell -NoProfile -ExecutionPolicy Bypass -File "<folder>\SRRVRR.ps1"`, which is what
`Start SRRVRR.bat` does. Files from a downloaded zip carry Windows' downloaded mark; they still load
because of `-ExecutionPolicy Bypass`, so don't start it any other way.

**Check every file before it loads.** If your launcher checks SRRVRR's files against a list of hashes
before starting it, the list must cover `SRRVRR.ps1` and every file under `modules\` and `web\`, plus the
temperature sensor library's `.dll` files under `lib\` if you installed it. Install the launcher release
that knows a new SRRVRR version's files before you install that version, or the check will refuse it
(or, worse, let unchecked files load).

**Exit codes.** What a launcher should do when SRRVRR exits:

| Exit code | Meaning | Start it again? |
|---|---|---|
| `0` | A clean stop (requested, or Ctrl+C) | No |
| `2` | A settings error (the log says which) | No: it would fail again the same way |
| `3` | Refused to start: the data folder is shared or on a network drive, its permissions can't be set, or another copy is using it | No |
| Anything else | A crash | Yes, up to 3 times in 10 minutes; then stop trying and log it |

**Stopping it.** Run `SRRVRR.ps1 -Stop` (what `Stop SRRVRR.bat` does) from SRRVRR's own folder. It stops
only the copy in that folder: it signals it, and SRRVRR saves its history and Maintenance and exits with
code 0. If it hasn't exited after 10 seconds, the stopper ends it, which leaves a crash-looking exit code.
So before signalling, the stopper writes `state\stop-requested` in SRRVRR's own folder: a launcher should
treat any exit within 60 seconds of that file's time as a requested stop, not restart it, and delete the
file. Closing SRRVRR's console window is a hard stop with no saving.

**Where its data goes.** `state` and `logs` go under `DataPath` (see
[Data folder and logs](#data-folder-and-logs)); `state\stop-requested` always stays in SRRVRR's own
folder, where a launcher can find it. Updating means replacing the code only (see [Settings](#settings)).

## Troubleshooting

- **Another PC gets "Bad Request - Invalid Hostname" (HTTP 400):** SRRVRR is running without
  administrator (its window says "Loading without Admin Privs..."), so Windows only lets it
  answer on that machine. Close it and start it again, clicking **Yes** on the prompt.
- **Page won't load from another PC:** make sure it was started as administrator, and check the
  firewall rule: `Get-NetFirewallRule -DisplayName 'SRRVRR'`.
- **"The process cannot access the file because it is being used by another process":**
  something else is using the port. Pick another `Port`.
- **GPU tile says "... not found, showing ...":** `PreferredGpu` doesn't exactly match any card's
  name. The startup message lists the names Windows reports; copy one into the config.
- **GPU shows N/A:** the machine has no GPU performance counters (e.g. no GPU or a basic display driver).
- **CPU or memory shows "Temp n/a":** hover it for the reason. "Not set up" or "the PawnIO driver
  is missing": run `Install Temperature Sensors.bat`. "Needs administrator": start SRRVRR as
  administrator. A gray "No sensor" on the Memory tile means the sticks have no
  temperature sensor (most DDR4); nothing is wrong.
- **Script won't run (execution policy):** use the `.bat` launcher, or run
  `powershell -ExecutionPolicy Bypass -File .\SRRVRR.ps1`.

## How it works

A background loop reads Windows performance counters once per second
(`Processor Information`, `Memory`, `Network Interface`, `GPU Engine`, `GPU Adapter Memory`,
`Process`) and keeps the latest values in memory. A second, slower loop reads what changes slowly or costs more
every 5 seconds, including, when the file server is there, `SMB Server Shares` and `SMB Server Sessions` for the
Transfers card (with the network and disk counters again, so the once-a-second reading pays nothing for it). A small built-in web server (`HttpListener`)
serves the dashboard page at `/` and the latest readings as JSON at `/stats`, which the page polls.
`/stats` has a `transfers` value for the Transfers card (`available`, `reason`, the `bottleneck` with its three
numbers, the busiest `shares` and `pcs`), and `/history` has two more lines, `smbRead` and `smbWrite`.
`/stats` also reports `tickMs`, the time each reading takes, and `slowMs`, the time of the slow loop's last pass, so
SRRVRR's own cost stays visible, and `version`,
which the page shows in its header. The version is the one line in the `VERSION` file in SRRVRR's folder, read
once at startup (`dev` when there is no file, `unknown` with a note in the startup log when the file isn't one
line of 1 to 64 printable ASCII characters). A release carries `VERSION` holding its tag (such as `v0.8.0`);
anything else shows in amber on the page.
`/stats?since=<id>` adds the events after that id (at most 50), `/events?days=n` returns the logged
events of the last n days, newest first, and `POST /maintenance` (with an `X-SRRVRR: 1` header, a JSON
body and this page's own origin) turns Maintenance on or off.

The code is `SRRVRR.ps1` plus modules in `modules\` (the counter math, settings, and the web server's
request handling), always loaded from SRRVRR's own folder, never by name. The page is plain files in
`web\` (`index.html`, `app.js`, `style.css`, and the logos in `img\`), read from disk on every request, so
a change to the page shows with a browser refresh. The web server answers only requests addressed to
this machine's own names and addresses, serves only those page files, and answers anything else with
an error.
The GPU is picked through Windows' DirectX adapter list in the registry (the same names dxdiag
shows), which uses the same adapter IDs as the GPU counters and also gives the card's vendor ID
for the logo: NVIDIA (`10DE`), AMD (`1002`/`1022`) or Intel (`8086`); anything else gets a
plain GPU icon.

The processor's name and maker come from Windows (`Win32_Processor`), with the trademark marks and
clock speed left out. Each memory stick's maker, type and speed come from `Win32_PhysicalMemory`.
Windows reports the maker as a name ("G Skill Intl"), as a raw JEDEC ID code (e.g. `04CD`), or
not at all, so SRRVRR recognizes all three, falling back to the part number's prefix (e.g.
`F5-` for G.Skill). Both are read once at startup.

Logos and icons ship with SRRVRR (in `web\`), so the page needs no internet access: Valheim emblem
(valheimgame.com), Plex chevron (Plex Media Server), NVIDIA eye mark (nvidia.com), AMD arrow
(amd.com), Intel wordmark (Intel's 2020 logo), memory makers' logos (Samsung, Kingston and
Corsair from [Simple Icons](https://simpleicons.org), CC0; SK hynix, Micron and ADATA from
Wikimedia Commons, public domain; G.Skill from gskill.com), shown in one color to match the
theme, and CPU/RAM/network/GPU/bell icons from
[Lucide](https://lucide.dev) (ISC license). The alert ding is generated by the browser (a fading
880 Hz tone through the Web Audio API), so there's no sound file either.

## Checks and tests

For anyone changing SRRVRR. `tools\Invoke-Checks.ps1` runs every check, the same way on your machine and
on GitHub: a parse of every script (and a compile of the C# inside it, as Windows PowerShell 5.1 does),
an ASCII check, a scan for private details, PSScriptAnalyzer, and the Pester tests in `tests\`. It needs
Pester 6.2.0 and PSScriptAnalyzer 1.25.0 for your account:

```powershell
Install-Module Pester -RequiredVersion 6.2.0 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser -Force
.\tools\Invoke-Checks.ps1          # add -Smoke to also start real test copies
```

To try a branch without touching a running SRRVRR, build a test copy in its own folder and start it there
(it listens on port 8091): `.\tools\New-TestBuild.ps1 -Ref <branch> -Destination <folder>`. A test copy
writes its own `VERSION`, `test-<ref>+<first 7 of the commit>`, so its page shows that in amber. Then
`.\tools\Measure-SRRVRR.ps1 -Folder <folder>` measures its CPU, memory and response times against the
budgets in `tools\budgets.psd1`. None of `tests\`, `tools\` or `docs\` is part of a release.

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

Valheim, Plex, NVIDIA, AMD, Intel, Samsung, SK hynix, Micron, Kingston, Corsair, G.Skill and
ADATA logos are trademarks of their respective owners and are
used only to identify those products; they are not covered by this license. The CPU, memory,
network, GPU, storage and bell icons are from [Lucide](https://lucide.dev) (ISC license).
`Install-TemperatureSensors.ps1` downloads LibreHardwareMonitor's library (MPL-2.0) and the
PawnIO driver from their own GitHub releases; neither is part of this repository.
