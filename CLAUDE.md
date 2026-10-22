# SRRVRR: notes for Claude

Ops-health dashboard for a Windows home server: one PowerShell script serves a live page.
Version is in `README.md`, history in `CHANGELOG.md`, and the *why* behind decisions in
`docs/DECISIONS.md`. Read those before proposing changes that touch an earlier decision.

## Layout

- **`SRRVRR.ps1`** holds everything, in this order:
  1. Startup UI: background spinner, `Write-Status` / `Set-Step`, `Invoke-Reported`, the `trap` that prints one-line errors.
  2. Settings: defaults, then `SRRVRR.config.psd1` (legacy `SystemMonitor.config.psd1`), then `-Port`; retired keys, validation.
  3. Processes catalog (`$services`); performance counter discovery.
  4. GPU pick: the DirectX registry list (names, vendor IDs) joined to GPU-counter LUIDs; `nvidia-smi` for temperature.
  5. ETW per-process network tracer: C# via `Add-Type`, P/Invoke, hand-laid structs.
  6. Fast sampler runspace (every 1 s): counters, GPU, Processes table.
  7. Slow sampler runspace (5 s tick): GPU temperature every 5 s, drives every 30 s, pending restart every 60 s.
  8. Page: HTML/CSS/JS in a here-string, with logos and icons embedded.
  9. Firewall reconcile (delete and recreate the rules), `HttpListener` (`/` page, `/stats` JSON), the running spinner.
- **`/stats` JSON** is the contract between the back end and the page.
- **Other files:** `Start SRRVRR.bat` (Loading message, admin check). `SRRVRR.config.example.psd1` (every setting, documented). The user's `SRRVRR.config.psd1` is gitignored.

## Rules

- **Target platform:** Windows PowerShell 5.1, with C# 5 inside `Add-Type`.
- **Keep `SRRVRR.ps1` pure ASCII.** PowerShell 5.1 reads it as ANSI, so build symbols at runtime: `[char]0x00B7` in PowerShell, `String.fromCharCode(...)` in JS. Never type `\u` escapes through tools: they get converted to the literal character.
- **After every edit:** parse the script with the PowerShell parser and count non-ASCII lines.
- **Windows networking and firewall commands:**
  - Call them through `Invoke-Reported`, which prints PowerShell's progress as plain lines.
  - Pass `-ErrorAction Stop` explicitly; they ignore `$ErrorActionPreference`.
- **Startup output** goes through `Set-Step` and `Write-Status`. Keep the `Steps` count in sync with the number of `Set-Step` calls. "Reticulating Splines..." stays the last step.
- **Anything slower than ~50 ms** belongs in the slow sampler, never in the 1-second loop.
- **Settings:** retired settings go in `$retired`, which prints a note instead of an error. Invalid settings fail fast with one plain message.
- **Firewall:** local network only by default. Public IPs are allowed only via `AllowPublicAddresses`: single addresses, and only in an `Allowlist`.
- **No personal details in committed files:** no IPs, share paths, or hostnames other than "SRRVRR".
- **Assets** are embedded as data URIs or inline SVG. Credit sources in the README (Lucide is ISC; the logos are trademarks).
- **Scope:** ops health only (up / struggling / about to break). No governance features such as backup status.

## Workflow (the owner does UAT; merge only on their OK)

1. Branch `feature/<topic>`. Stack dependent PRs, and rebase the later ones after fixing a lower one.
2. Test locally with a copy of the script on a spare `-Port` (e.g. 8091; 8085 is taken on the dev PC).
   - Run it non-elevated; "needs administrator" for the firewall and ETW is expected.
   - Never change the dev PC's firewall.
3. In the same PR, add a `CHANGELOG.md` `[Unreleased]` entry and update the README.
4. Commit and PR messages:
   - Write them to a BOM-less UTF-8 file under `.git\`, then use `git commit -F` / `gh pr create --body-file`. PowerShell 5.1 mangles quotes in native command arguments.
   - End with the attribution lines.
5. Stage a UAT build next to the live app (`SRRVRR - test.ps1` + `Start SRRVRR - test.bat`). Never touch the user's config.
6. After the OK:
   - Merge the PRs in order.
   - Deploy the 3 code files (the `.bat` with CRLF line endings) and verify them with a hash compare.
   - Remove the test files.
7. Release:
   - A docs PR moves `[Unreleased]` to the new version and bumps the README version.
   - Merge it, create an annotated tag `vX.Y.Z`, and run `gh release create` with that version's changelog section as the notes.
   - Semantic Versioning, staying on 0.x (the owner isn't ready for 1.0).

## Backlog

- **Plex:** active streams (direct play vs transcode) via Plex's local API. The token is read from Plex's own storage on the server, never from the config file.
- **Valheim:** players online via a Steam A2S query (game port + 1).
- **Storage card:**
  - Narrower usage bars.
  - A per-drive read/write throughput column after Health.
- **Later, a Linux/container port:** a new collector (Python or Go: `/proc`, `/sys`, eBPF, `nvidia-smi`) emitting the same `/stats`. Check node_exporter, Netdata and Glances first.
- **Tech debt:**
  - Pester tests and PSScriptAnalyzer in GitHub Actions.
  - Split the script into modules.
