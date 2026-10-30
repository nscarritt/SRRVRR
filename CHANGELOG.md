# Changelog

All notable changes to SRRVRR are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html). While the version is `0.x`, the
project is still settling: new minor versions may include breaking changes, which are always
called out under **Changed** or **Removed** with upgrade notes.

## [Unreleased]

### Added

- **A crash and error log**, `logs\srrvrr-YYYY-MM-DD.log`: every startup step, settings problems,
  errors from the background readers, crashes with their details, and a last line saying why SRRVRR
  stopped and its exit code. 20 MB a day at most (old files are removed once the event log arrives).
  ([#48](https://github.com/nscarritt/SRRVRR/issues/48))
- **`DataPath`:** keep the `state` and `logs` folders on another local drive. If it's missing or
  can't be written, SRRVRR uses its own folder until the next restart and logs a flag; the Storage
  card watches that drive, even a USB one, and shows it as Missing when it's gone. SRRVRR refuses to
  start if the data folder is shared on the network, on a network drive, or used by another copy.
  ([#48](https://github.com/nscarritt/SRRVRR/issues/48))
- **Exit codes** for whatever starts SRRVRR: 0 a clean stop, 2 a settings error, 3 a refusal to
  start, anything else a crash. SRRVRR also stops with a crash code if one of its background readers
  dies, so a launcher can start it again. ([#48](https://github.com/nscarritt/SRRVRR/issues/48))
- New settings `LogRetentionDays`, `MaintenanceHours` and `MaintenanceMaxHours` (Maintenance itself
  arrives in a later release). ([#48](https://github.com/nscarritt/SRRVRR/issues/48))

- **Design for the v0.7.0 core** ([docs/specs/2026-10-28-srrvrr-core-design.md](docs/specs/2026-10-28-srrvrr-core-design.md)):
  modules with tests, the page in its own files, 15 minutes of history kept on the server, server-side alerts, an
  event log and a crash log, Maintenance and a Flagged list, with its test plan
  ([docs/plans/2026-10-29-srrvrr-core-test-plan.md](docs/plans/2026-10-29-srrvrr-core-test-plan.md)) and implementation plan
  ([docs/plans/2026-10-29-srrvrr-core-implementation-plan.md](docs/plans/2026-10-29-srrvrr-core-implementation-plan.md)). Design only; nothing changes yet.
- **Checks and tests:** `tools\Invoke-Checks.ps1` runs a parse and C# compile check, an ASCII check, a
  private-details scan, PSScriptAnalyzer and the Pester tests, locally and on every pull request
  (GitHub Actions, in Windows PowerShell 5.1). `tools\New-TestBuild.ps1` builds a test copy of any
  branch in its own folder, and `tools\Measure-SRRVRR.ps1` checks it against the performance budgets.
  ([#47](https://github.com/nscarritt/SRRVRR/issues/47))
- **`tickMs` in `/stats`:** how long each one-second reading takes, so SRRVRR's own cost stays
  visible. ([#47](https://github.com/nscarritt/SRRVRR/issues/47))

### Changed

- **Stopping is clean.** `Stop SRRVRR.bat` (`SRRVRR.ps1 -Stop`) now stops only the SRRVRR in its own
  folder, by signalling it to save and close, and ends it only if it hasn't closed after 10 seconds.
  Ctrl+C is a clean stop too. Closing the window is still a hard stop. A settings error now exits
  with code 2, not 1. **Upgrading:** to stop a test copy, use the `Stop SRRVRR.bat` in its folder.
  ([#48](https://github.com/nscarritt/SRRVRR/issues/48))
- **Test copies keep to themselves.** A copy built by `tools\New-TestBuild.ps1` uses its own firewall
  rules ("SRRVRR (test)") and its own network trace, so even run as administrator it never changes the
  live copy's. ([#48](https://github.com/nscarritt/SRRVRR/issues/48))
- **The code is split into modules and the page into its own files.** `SRRVRR.ps1` loads
  `modules\` (counters, settings, the web server's request handling) from its own folder, and serves
  the page from `web\` (`index.html`, `app.js`, `style.css`, logos in `img\`), read on every request,
  so a page change shows with a refresh. The page looks and works exactly as before. **Upgrading:**
  copy the `modules` and `web` folders along with `SRRVRR.ps1`; see [Settings](README.md#settings).
  ([#47](https://github.com/nscarritt/SRRVRR/issues/47))
- **The web server answers only what it serves.** A request addressed to anything but this machine's
  own names or addresses gets "421 Misdirected Request" (this blocks a website from reaching SRRVRR
  through a DNS trick), any method but GET gets 405, and an unknown path gets 404 instead of the page.
  ([#47](https://github.com/nscarritt/SRRVRR/issues/47))

- **Memory sticks without a temperature sensor now say so.** The Memory tile shows a gray "No
  sensor" (hover names the sticks) instead of leaving the temperature blank, which looked broken.
  Most DDR4 has no sensor; DDR5 does.

## [0.6.0] - 2026-10-28

Hardware identity and temperatures: the CPU and Memory tiles name the parts, show the maker's
logo and the temperature, and SRRVRR is easier to start, stop and set up.

### Added

- **`Stop SRRVRR.bat`** (and `SRRVRR.ps1 -Stop`): stops whichever SRRVRR is running, the live
  or the test version, closes its window, and says what it stopped. It asks for administrator
  only when SRRVRR was started as administrator.
  ([#39](https://github.com/nscarritt/SRRVRR/pull/39))
- **Processor and memory names:** the CPU tile names the processor ("Intel Core i7-13700K") and
  shows the Intel or AMD logo; the Memory tile names the maker and type ("G.Skill DDR5", or
  "Mixed") and shows the maker's logo for the seven biggest memory makers: Samsung, SK hynix,
  Micron (and Crucial), Kingston, Corsair, G.Skill and ADATA. Hover the memory line for each
  stick's slot, part number, size and current speed.
  ([#37](https://github.com/nscarritt/SRRVRR/pull/37))
- **CPU and memory temperatures** on their tiles, every 5 seconds, styled like the GPU's: the CPU
  package temperature (amber at 80 °C, red at 90 °C) and the hottest memory stick (amber at
  70 °C, red at 80 °C), each core or stick on hover. Read through LibreHardwareMonitor's sensor
  library and the PawnIO driver, which the new `Install-TemperatureSensors.ps1` downloads
  (pinned versions, SHA-256 and signature checked) and sets up. When they can't be read, the
  tile shows an amber "Temp n/a" with the reason on hover.
  ([#38](https://github.com/nscarritt/SRRVRR/pull/38))
- **`Install Temperature Sensors.bat`:** double-click to set up the temperatures. It asks for
  administrator and its window stays open at the end. The "Temp n/a" hint now names it.
  ([#44](https://github.com/nscarritt/SRRVRR/pull/44))

### Changed

- **`Start SRRVRR.bat` asks for administrator on its own**, so a plain double-click starts the
  version other PCs can open. Saying No still starts it without administrator, as before.
  Before, a double-click quietly started the local-only version, and other PCs got "Bad
  Request - Invalid Hostname". ([#43](https://github.com/nscarritt/SRRVRR/pull/43))

### Fixed

- **The temperature setup no longer flashes a window and vanishes.** Right-click > **Run with
  PowerShell** on `Install-TemperatureSensors.ps1` could close at once and install nothing; use
  the new `.bat` instead. The script's own first window now waits for the administrator window
  and stays open when something went wrong: a declined prompt, or an administrator window that
  couldn't start the setup. Started from a mapped drive, it gives the administrator window the
  network path, since administrator windows don't see mapped drives.
  ([#44](https://github.com/nscarritt/SRRVRR/pull/44))

## [0.5.0] - 2026-10-27

Alerts: know when someone joins Valheim or starts a Plex stream, with an optional soft ding.

### Added

- **Alerts:** a banner slides down from the top of the page when a Valheim player joins or
  leaves ("Ivar joined Valheim · 2 players online"), and closes by itself or with ×. A
  **Sound** button in the header turns on a soft ding with each alert, remembered per browser.
  ([#33](https://github.com/nscarritt/SRRVRR/pull/33))
- **Plex stream alerts:** a banner when a stream starts, with the title, who, the device and app,
  and how it plays (direct play, direct stream, or transcoding from one quality to another on
  the GPU or CPU), plus its bitrate. The Plex hover now also names the device.
  ([#34](https://github.com/nscarritt/SRRVRR/pull/34))
- README opens with a screenshot of a live dashboard (private share names blurred), and has a
  table of contents linking every section. ([#27](https://github.com/nscarritt/SRRVRR/pull/27),
  [#31](https://github.com/nscarritt/SRRVRR/pull/31))
- **Security policy** (`SECURITY.md`): how to report a vulnerability privately through GitHub,
  what counts as one, and the known by-design limitations. Linked from the README security
  warning. ([#28](https://github.com/nscarritt/SRRVRR/pull/28))

### Changed

- **Drive read/write column**: fixed-width cells that don't shift as numbers change, units that
  scale from B/s to GB/s, and colors by load: amber at 70% and red at 90% of the drive's typical
  maximum for its type (NVMe, SATA SSD, hard drive, USB), raised to the fastest speed seen.
  ([#29](https://github.com/nscarritt/SRRVRR/pull/29))

### Fixed

- **Plex details appear even when Plex starts after SRRVRR.** The Plex token used to be looked up
  once, at startup; if Plex wasn't running yet under its own Windows account, stream details stayed
  unavailable until SRRVRR was restarted. SRRVRR now looks again every minute until it finds it.
  ([#32](https://github.com/nscarritt/SRRVRR/pull/32))

## [0.4.1] - 2026-10-23

Storage polish and friendlier guidance.

### Added

- **Live read/write speed per drive** on the Storage card ("R 12 MB/s · W 3 MB/s"), updated every
  second. ([#23](https://github.com/nscarritt/SRRVRR/pull/23))

### Changed

- Storage card usage bars are about half as wide, to make room and reduce visual weight.
  ([#23](https://github.com/nscarritt/SRRVRR/pull/23))
- When a Valheim server never answers the status query, the message now names the fix: start it
  with `-public 1` (crossplay servers never answer). ([#24](https://github.com/nscarritt/SRRVRR/pull/24))
- **No longer limited to English Windows** in the README: counters are read through .NET, which
  resolves English counter names on any display language. Tested on English Windows only.
  ([#25](https://github.com/nscarritt/SRRVRR/pull/25))

## [0.4.0] - 2026-10-23

What the servers are doing: Plex streams and Valheim players, without adding visual noise.

### Added

- **Plex activity** in a quiet line under the Plex row: active streams and how many are
  transcoding vs direct play ("2 streams · 1 transcoding"), with who is watching what on hover.
  Read every 10 seconds from Plex's local API using the token from Plex's own settings (never
  stored, printed or sent to the page). ([#20](https://github.com/nscarritt/SRRVRR/pull/20))
- **Valheim activity** in a quiet line under the Valheim row: players online, status-query reply
  time (amber over 250 ms) and CPU in whole cores, with player names on hover. Read every
  10 seconds via Valve's A2S query on the new `ValheimPort` setting (default 2456) + 1. A server
  that stops answering shows in amber; one that never answers shows quietly. Requires the server
  to run with `-public 1`: servers started with `-public 0` (or in crossplay mode) don't answer
  the query. ([#21](https://github.com/nscarritt/SRRVRR/pull/21))

### Changed

- **License changed from MIT to the
  [PolyForm Noncommercial License 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0)**:
  noncommercial use only. Versions 0.1.0 to 0.3.0 remain available under MIT.
  ([#18](https://github.com/nscarritt/SRRVRR/pull/18))

### Fixed

- `/stats` now declares UTF-8, so non-English names display correctly in every client.
  ([#21](https://github.com/nscarritt/SRRVRR/pull/21))

### Upgrading from 0.3.0

- Optional new setting `ValheimPort` (default 2456). For the Valheim player count, start the
  server with `-public 1`.

## [0.3.0] - 2026-10-22

Server health at a glance: storage, uptime and restarts, and GPU temperature.

### Added

- **Storage card**: every local drive with a usage bar (amber at 85% full, red at 95%),
  used/total space and the disk's health as Windows reports it (SMART-based for physical disks).
  Checked every 30 seconds by a new second background sampler, so slow checks never stall the
  once-a-second graphs. ([#14](https://github.com/nscarritt/SRRVRR/pull/14))
- **Uptime and pending restart** in the header: "Up 3 days, 4 hours", plus a "Restart pending"
  badge when Windows Update or the servicing stack is waiting on a restart (checked every
  60 seconds). ([#15](https://github.com/nscarritt/SRRVRR/pull/15))
- **GPU temperature** on the GPU tile for NVIDIA cards, from `nvidia-smi`, every 5 seconds;
  amber at 80 °C, red at 90 °C. ([#16](https://github.com/nscarritt/SRRVRR/pull/16))

### Changed

- Startup step 5 is now "Starting the background samplers" and lists what each sampler checks
  and how often. ([#14](https://github.com/nscarritt/SRRVRR/pull/14))

## [0.2.0] - 2026-10-22

The first full day of features: per-program stats, a settings file, a friendlier console, and
the rename from System Monitor to SRRVRR.

### Added

- **Processes table** under the graphs showing CPU, memory, GPU and network up/down for the
  Valheim dedicated server and Plex (including Plex Transcoder and other helpers), or "Offline"
  when not running. Per-program network comes from Windows' kernel network events and needs
  administrator. ([#1](https://github.com/nscarritt/SRRVRR/pull/1))
- **Valheim and Plex logos** next to their names in the Processes table.
  ([#3](https://github.com/nscarritt/SRRVRR/pull/3))
- **Tile icons** for CPU, Memory, GPU and Network, with larger tile titles. The GPU tile shows
  the card maker's logo (NVIDIA, AMD or Intel, or a plain GPU icon), picked from the card's
  vendor ID. ([#4](https://github.com/nscarritt/SRRVRR/pull/4),
  [#10](https://github.com/nscarritt/SRRVRR/pull/10))
- **Settings file** `SRRVRR.config.psd1` (with a commented `SRRVRR.config.example.psd1`): `Port`,
  `FirewallScope` (`LocalSubnet`, `Allowlist`, `Blocklist`), `FirewallAddresses`,
  `AllowPublicAddresses`, `PreferredGpu` and `Processes` on/off switches. The file is never
  committed and never overwritten by updates. ([#6](https://github.com/nscarritt/SRRVRR/pull/6),
  [#10](https://github.com/nscarritt/SRRVRR/pull/10))
- **`AllowPublicAddresses`** (off by default, at your own risk): lets an `Allowlist` include
  single public IPs, with a startup warning, a README security section and a liability
  disclaimer. ([#6](https://github.com/nscarritt/SRRVRR/pull/6))
- **MIT license.** ([#7](https://github.com/nscarritt/SRRVRR/pull/7))
- **Console status:** "Loading..." (or "Loading without Admin Privs...") the moment the launcher
  starts, numbered startup steps with what each one found, a spinner while each step works,
  PowerShell's own progress messages printed as plain lines, and a "Running..." spinner once the
  page is up. Step 8 reticulates splines. ([#8](https://github.com/nscarritt/SRRVRR/pull/8),
  [#9](https://github.com/nscarritt/SRRVRR/pull/9),
  [#11](https://github.com/nscarritt/SRRVRR/pull/11))
- The startup line shows both the machine's name and its network IP address.
  ([#10](https://github.com/nscarritt/SRRVRR/pull/10))

### Changed

- **Renamed from System Monitor to SRRVRR**: the repository, files (`SRRVRR.ps1`,
  `Start SRRVRR.bat`, `SRRVRR.config.psd1`), console messages and firewall rule names. The page
  title and header always read "SRRVRR". ([#12](https://github.com/nscarritt/SRRVRR/pull/12))
- **GPU tile counts one card**: `PreferredGpu` by its exact name as Windows reports it (e.g.
  `'NVIDIA T600'`), otherwise the GPU with the most video memory, so built-in graphics no longer
  skew the numbers. The console shows the card and its size, e.g. "NVIDIA T600 · 4 GB".
  ([#5](https://github.com/nscarritt/SRRVRR/pull/5),
  [#10](https://github.com/nscarritt/SRRVRR/pull/10))
- **Firewall rule is always set up** and rebuilt on every start to match the settings.
  ([#6](https://github.com/nscarritt/SRRVRR/pull/6),
  [#10](https://github.com/nscarritt/SRRVRR/pull/10))
- Processes table columns have fixed widths, so the table no longer jumps as numbers change.
  ([#2](https://github.com/nscarritt/SRRVRR/pull/2))
- Errors that stop the app show one plain line ("SRRVRR stopped: ...") instead of PowerShell's
  error block. ([#9](https://github.com/nscarritt/SRRVRR/pull/9))

### Removed

- **Breaking:** the `ListenAddress`, `OpenFirewall` and `GpuFallback` settings and the
  `-OpenFirewall` switch. The app always listens on the machine's own addresses, always sets up
  the firewall rule, and falls back to the GPU with the most video memory. Old configs still
  load and print a note that these settings can be deleted.
  ([#10](https://github.com/nscarritt/SRRVRR/pull/10))

### Fixed

- Without administrator, a failed firewall update was followed by a false "port open" message;
  it now says the rule couldn't be updated. ([#6](https://github.com/nscarritt/SRRVRR/pull/6))

### Security

- The page is limited to the local network: firewall addresses must be private unless
  `AllowPublicAddresses` is turned on, and even then only single public IPs in an `Allowlist`
  are accepted. ([#6](https://github.com/nscarritt/SRRVRR/pull/6))

### Upgrading from 0.1.0

- Rename `SystemMonitor.config.psd1` to `SRRVRR.config.psd1` (the old name is still read, with a
  note).
- `PreferredGpu` needs the card's full name, e.g. `'NVIDIA T600'` rather than `'T600'`.
- The old "System Monitor" firewall rules are removed automatically on first start.

## [0.1.0] - 2026-10-20

First version, as "System Monitor".

### Added

- Live dashboard in the browser with CPU, Memory, GPU and Network tiles, each with a 60-second
  graph, updated every second. Light and dark themes; works on phones.
- One PowerShell script with a built-in web server on port 8099, plus a `.bat` launcher.
- `-OpenFirewall` switch to add a Windows Firewall rule limited to the local network.
- README with setup and troubleshooting.

[Unreleased]: https://github.com/nscarritt/SRRVRR/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/nscarritt/SRRVRR/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/nscarritt/SRRVRR/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/nscarritt/SRRVRR/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/nscarritt/SRRVRR/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/nscarritt/SRRVRR/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/nscarritt/SRRVRR/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/nscarritt/SRRVRR/releases/tag/v0.1.0
