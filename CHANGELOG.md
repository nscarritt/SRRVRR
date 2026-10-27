# Changelog

All notable changes to SRRVRR are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html). While the version is `0.x`, the
project is still settling: new minor versions may include breaking changes, which are always
called out under **Changed** or **Removed** with upgrade notes.

## [Unreleased]

### Added

- README opens with a screenshot of a live dashboard (private share names blurred).
- README table of contents linking every section.
- **Security policy** (`SECURITY.md`): how to report a vulnerability privately through GitHub,
  what counts as one, and the known by-design limitations. Linked from the README security
  warning.

### Changed

- **Drive read/write column**: fixed-width cells that don't shift as numbers change, units that
  scale from B/s to GB/s, and colors by load: amber at 70% and red at 90% of the drive's typical
  maximum for its type (NVMe, SATA SSD, hard drive, USB), raised to the fastest speed seen.

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

[Unreleased]: https://github.com/nscarritt/SRRVRR/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/nscarritt/SRRVRR/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/nscarritt/SRRVRR/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/nscarritt/SRRVRR/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/nscarritt/SRRVRR/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/nscarritt/SRRVRR/releases/tag/v0.1.0
