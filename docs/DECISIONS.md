# Decision log

Why SRRVRR is built the way it is. Newest first. Each line: **decision**, why, and what was
rejected. Add a line whenever a choice is made that someone might later want to undo.

## 2026-10-22

- **License: PolyForm Noncommercial 1.0.0** (was MIT). The owner doesn't want commercial use.
  *Rejected:* PolyForm Strict, which bans sharing and changes entirely. Not retroactive: 0.1.0–0.3.0 stay MIT.
- **Changelog plus Semantic Versioning, staying on 0.x.** Each release is traceable to its PRs. *Rejected:* 1.0, because settings and behavior are still changing.
- **Ops-health scope only:** is it up, is it struggling, is it about to break. Governance is handled elsewhere (backups are Backblaze). *Rejected:* a backup-status tile.
- **Slow checks get their own background runspace** (5 s tick). Disk health (~300 ms) and `nvidia-smi` (~130 ms) would make the 1-second graphs stutter. *Rejected:* running them in the fast loop.
- **GPU temperature from `nvidia-smi`, NVIDIA only.** It's installed with the driver; AMD and Intel have no built-in equivalent. *Rejected:* third-party sensor tools.
- **Disk health from Windows' storage APIs** (`Get-PhysicalDisk`, SMART-based, with `Get-Disk` as fallback). Built in, no extra software. *Rejected:* smartctl.
- **Console transparency:** numbered startup steps, PowerShell's own progress printed as lines, and spinners while working, so non-technical users can see it isn't malware. *Rejected:* hiding PowerShell's progress bar.
- **Renamed to SRRVRR;** the page header is hardcoded. The app is the server's dashboard, not a generic tool. *Rejected:* showing the machine name looked up at runtime.
- **Simpler settings.**
  - Always listen on all of the machine's own addresses.
  - Always manage the firewall rule.
  - `PreferredGpu` is the card's exact Windows name; otherwise fall back to the GPU with the most video memory, picking the logo by vendor ID.
  - *Rejected:* separate `ListenAddress`, `OpenFirewall` and `GpuFallback` options.
- **Firewall is local-network only.** The page has no login and no encryption. Public IPs are opt-in (`AllowPublicAddresses`): single IPs, allowlist only, with a warning on every start. *Rejected:* an "Any" scope.
- **Settings live in a gitignored `.psd1` data file, with a committed example.**
  - Updates never overwrite the user's settings, and nothing personal is published.
  - A data file can't run code.
  - *Rejected:* settings hardcoded in the script.
- **Owner-run UAT before every merge,** with a side-by-side test build on the real server. Owner's choice: enterprise-style change control.
- **Plex logo rebuilt as a vector** from Plex's own chevron mask and colors. Plex's site blocks downloads, and its favicon is only 32 px. Other logos come from the vendors' sites; icons are Lucide (ISC).
- **Per-process network via an ETW kernel event session,** consumed live. Windows has no per-process network counter. *Rejected:* estimating by port, which misses Steam relay and Plex transcoder traffic.
- **Per-process memory is private working set,** the same number Task Manager shows. *Rejected:* total working set, which double-counts shared memory.
- **Plex row counts every `Plex*` process** (transcoder and helpers), since that's where streaming load shows up. The Valheim row is `valheim_server`.

## 2026-10-20

- **One PowerShell script with a built-in web server** (`HttpListener`). Nothing to install on a Windows server; native access to counters, registry and firewall; deploy is a single file copy. *Rejected:* Python, which needs an install and libraries.
- **The browser polls `/stats` every 0.5 s.** Simple, and negligible load at this scale. *Rejected:* WebSockets.
- **Counters are read a whole category at a time,** with rates computed from deltas. `Get-Counter` took about 3.5 s with 676 GPU engine instances. *Rejected:* `Get-Counter`.
- **Port 8099,** because 8085 is used by PRTG on the dev PC.
