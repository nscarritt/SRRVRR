# SRRVRR core (v0.7.0): design

Status: draft for the owner's review. Design sections 1 and 2 approved 2026-10-28; the data folder and sections 3
and 4 approved 2026-10-29; hardened after an adversarial review on 2026-10-29. Stories: #47 to #51, milestone
v0.7.0.

## Contents
- [Goals](#goals)
- [Baseline and budgets](#baseline-and-budgets)
- [1. Files and structure](#1-files-and-structure)
- [2. History, saving and data flow](#2-history-saving-and-data-flow)
- [3. Data folder](#3-data-folder)
- [4. Events, logs, banners and Maintenance](#4-events-logs-banners-and-maintenance)
- [5. Stopping, and the exit codes](#5-stopping-and-the-exit-codes)
- [6. Settings](#6-settings)
- [7. Testing and rollout](#7-testing-and-rollout)
- [8. Security](#8-security)
- [9. Details pinned during test planning](#9-details-pinned-during-test-planning)
- [Dependencies](#dependencies)
- [Not in this release](#not-in-this-release)

## Goals

The owner's request, in short:
- **Modules with tests,** and the page moved into its own files.
- **15 minutes of graph history kept on the server,** so it survives a refresh or a restart.
- **Alerts decided on the server, a 31-day event log, and a crash and error log.** In the owner's words: "if there
  is some type of crash, a log is written for later debugging", with "at least a month of retention."
- **A Maintenance checkbox** that silences alerts, and a **Flagged list** of what happened.

**Approach: module-first ("strangler").** New code, and existing code as it's touched, moves into modules. There's
no rewrite of everything at once. `SRRVRR.ps1` stays the entry point at the same path, with the same command line.

**Scope stays ops health** (is it up, is it struggling, is it about to break). The event log is part of that: it
records what went wrong and when.

## Baseline and budgets

Measured on the live server with v0.6.0, read-only, on 2026-10-28:

| Measure | Today | Budget for every PR |
|---|---|---|
| CPU: the SRRVRR process, as % of the whole machine, over 60 s | 0.50% (peak 1.2%) | 1% at most |
| Memory: private bytes after 60 minutes running | about 300 MB | within 25 MB of the previous release, measured the same way |
| `/stats` response | 1.9 KB; 18 ms median, 25 ms p95 | 30 ms p95, also while `/history` and `/events` are being requested |
| `/history`, `/events` responses | - | 50 ms each |
| Page load | 66.6 KB; about 75 ms | 150 ms |
| Startup to serving | 15 to 17 s | 20 s |
| Fast sampler tick (`tickMs`) | not reported yet (the 1 s cadence holds) | median within 10% (or 5 ms) of PR 1's median |
| Disk writes | none | up to 100 MB a day |
| UAT per PR | - | about 15 minutes |

PR 1 adds the tick time to `/stats` and a measuring tool, `tools\Measure-SRRVRR.ps1`, which takes these numbers
against `http://localhost:<port>` with nothing but read access. Each later PR's description carries its numbers
next to these.

Disk writes in more detail: history is about 100 KB saved every 5 minutes, about 29 MB a day. Each log file has a
20 MB daily cap, so the worst case for 31 days of both logs is about 1.2 GB.

Startup keeps to its budget by doing the slow new work after the server is already serving: log cleanup, loading
the event index, and the daily share check. The share list is read with CIM (`Win32_Share`), not the SmbShare
module, which can take seconds to load the first time.

## 1. Files and structure

| Path | What it is |
|---|---|
| `SRRVRR.ps1` | Entry point (same path and command line as today): settings, startup steps, samplers, the web server |
| `modules\Counters.psm1` | The counter math both samplers use (rates from deltas, per-core and per-process CPU) |
| `modules\History.psm1` | Ring buffers for the graph lines, saving and loading them |
| `modules\Events.psm1` | Raising events, suppressing repeats, the daily log files, the in-memory index and cleanup |
| `modules\Logging.psm1` | The crash and error log, with its once-a-minute throttle |
| `modules\Web.psm1` | Request handling as plain functions: routing, the host and origin checks, static files |
| `modules\Settings.psm1` | Loading and validating settings; the two C# exception classes (section 5), compiled once on import |
| `modules\Control.psm1` | The stop event, the folder hash, the lock file, exit codes and the test-build marker |
| `modules\Platform.psm1` | Thin wrappers over Windows calls (shares, volumes, permissions, firewall), so the rest can be tested with fakes |
| `web\index.html`, `web\app.js`, `web\style.css`, `web\img\` | The page, moved out of the script's here-string |
| `tests\` | Pester 5 tests |
| `tools\Measure-SRRVRR.ps1` | The budget measurements above |
| `tools\Invoke-Checks.ps1` | Parse, ASCII, PSScriptAnalyzer and Pester: one script used locally and by CI |
| `.github\workflows\checks.yml` | Runs `tools\Invoke-Checks.ps1` on a Windows runner; advisory at first |
| `state\`, `logs\` | Data, gitignored; under `DataPath` (section 3) |

**Modules:**
- They load only from SRRVRR's own `modules\` folder: `Import-Module -Name <full path> -Force` at the top of each
  runspace's script. They're never loaded by name, and `$env:PSModulePath` is never used.
- Files from a downloaded release carry the "downloaded from the internet" mark. They load because SRRVRR is
  always started with `-ExecutionPolicy Bypass` (by `Start SRRVRR.bat` and by a boot launcher), which runspaces
  inherit. The release notes say so.

**The page:**
- **It's read from disk on every request,** so a page change goes live with a browser refresh. `web\` files may be
  UTF-8. `.ps1` and `.psm1` files stay pure ASCII.
- **A fixed table of paths, never built from the URL:**
  - `/` serves `web\index.html`.
  - `/app.js` and `/style.css` serve those files.
  - `/img/<name>` serves a file in `web\img\` only when the name matches `^[a-z0-9-]+\.(svg|png)$`.
  - Each has a fixed content type and `X-Content-Type-Options: nosniff`.
  - Anything else is 404, where today every unknown path returns the page.
- **Methods:** `GET` only, except `POST /maintenance`. Anything else gets 405. No `Access-Control-*` header is ever
  sent.
- A missing or unreadable `web\` file is a 500 with a plain message and an error-log line.
- Assets move from data URIs in the script to files in `web\img\`.

**Packaging:**
- Releases ship only the files that run. `.gitattributes` marks `tests\`, `.github\`, `docs\`, `tools\`,
  `.gitattributes` and `.gitignore` as `export-ignore`, so a `git archive` of a tag holds only runtime files.
- `.gitignore` adds `state/` and `logs/`.

**Anything slower than about 50 ms** stays in the slow sampler, as today.

## 2. History, saving and data flow

**What the server keeps:** one reading per second, for 15 minutes, of each graph line: CPU, memory, GPU, network
in and network out. That's 900 numbers per line, about 100 KB in all.
- Numbers only, never names (no player names, titles or process names).
- Later features register their own lines by name (for example, v0.8.0's share traffic).

**Who holds it:**
- The fast sampler appends each second's readings to a fixed-size `double[]` ring per line, plus the newest
  reading's time. It takes a lock only for the append.
- Readers (the save, `/history`) take a copy under the same lock and work on the copy.
- JSON for history is written by hand (a `StringBuilder`), not with `ConvertTo-Json`, which is too slow on
  PowerShell 5.1 for 4,500 numbers.

**Saving:**
- The slow sampler saves every 5 minutes, and the stop path saves on a clean stop.
- It writes `state\history.json.tmp` and then swaps it in (`[IO.File]::Replace`, or a move when there's no file yet),
  so a crash mid-write never leaves half a file.
- The file holds a format version, the newest reading's time, the step (1 s) and the arrays.
- **At start,** the file is used if its newest reading is less than 15 minutes old. Missing seconds are `null`, so
  the time SRRVRR was down shows on the graph as a gap.
- A file over 2 MB, a damaged file, or one in a format version SRRVRR doesn't know is renamed `history.json.bad`
  (replacing any older `.bad`), and history starts empty. It's never a crash.
- A failed save shows on the status line and in the error log. It's never fatal.

**Data flow:**

| Request | When | Returns |
|---|---|---|
| `GET /stats` | Every 0.5 s, as today | Today's fields, unchanged, plus `tickMs`, `maintenance` (`on`, `untilMs`), `logRetentionDays`, `lastEventId` and `events: []` |
| `GET /stats?since=<id>` | Every poll after the first | The same, with up to 50 events newer than `<id>`, oldest first, and `eventsTruncated: true` if there were more. An unknown or future id returns the newest 50. |
| `GET /history` | Once on page load, and again after a reconnect | Every line's last 15 minutes |
| `GET /events?days=<n>` | When the Flagged list is opened | Up to the newest 1,000 logged events, newest first, from the in-memory index. `n` is a whole number from 1 to `LogRetentionDays` (default 31); anything else is 400. |
| `POST /maintenance` | When the checkbox changes | The new Maintenance state |

- **`/stats` keeps every field it has today,** so anything that reads it (including scripts that only check it's
  JSON) keeps working.
- **The page starts from `lastEventId`** and asks with `since` after that.
- **`/events` never reads the log files per request.** The event module keeps an index of the logged events,
  loaded once after startup and appended to as events are written.

**Graph buttons:** 60 s (the default) and 15 min. Each browser remembers its choice.

## 3. Data folder

**The setting:**
- **One setting, `DataPath`,** holds `state\` and `logs\`. The default is SRRVRR's own folder, as now. An install
  can point it at another local drive.
- SRRVRR creates `state\` and `logs\` inside `DataPath`. It never creates `DataPath` itself: if a drive came back
  under another letter, that would quietly recreate the folder somewhere else.

**Fallback:**
- If `DataPath` is missing or read-only at start, or a write there fails later, SRRVRR switches to `state\` and
  `logs\` in its own folder.
- It raises a flag event and says so on the status line.
- It stays on the fallback until the next restart, so one day's log is never split across two drives.

**Never on a share.** SRRVRR refuses to start (exit 3) if any network share's folder is the same as the data
folder, above it, or below it.
- Paths are compared after both are resolved to full paths with junctions followed, case-insensitively and by whole
  folder names (so a folder named `Log` doesn't match one named `Logs`).
- Only Windows' own special shares are ignored (`Win32_Share` types with the 0x80000000 bit set: `ADMIN$`, `IPC$`,
  and the drive-root shares such as `C$`). A hidden share someone created (any name ending in `$`) still counts.
- A data folder on a network path, or on a mapped network drive, is refused too. That includes SRRVRR's own folder
  when it's the fallback.
- If the share list can't be read, an elevated SRRVRR refuses (exit 3), and an unelevated test copy warns and goes
  on.
- The check runs on `DataPath` and on the fallback folder at start, and again once a day in the slow sampler. A
  share that appears later raises a flag event.

**One copy per data folder.** SRRVRR holds `state\srrvrr.lock` open exclusively while it runs. If another copy holds
it, the new copy refuses to start (exit 3) and names the folder. A test build therefore can't share the live copy's
history, Maintenance or logs, even if its config was copied from the live one.

**Permissions:**
- When SRRVRR runs elevated, it makes sure only SYSTEM and Administrators can write `state\` and `logs\`.
  - It removes write access for anyone else and leaves read access as it is, so the owner can still read the logs.
  - It turns inheritance off on both folders.
  - If it can't, it logs why and refuses to start (exit 3).
- An unelevated test copy skips this and says so on the console.
- **Limits on what SRRVRR reads back:** it reads `history.json` only up to 2 MB and `maintenance.json` only up to
  4 KB. A Maintenance end time read from the file is held to at most `MaintenanceMaxHours` from now.

**The drives card:**
- It watches the drive that holds the data folder, even when Windows reports it as removable. Today the card lists
  fixed drives only.
- The drive is found with `Win32_Volume` (so folder mount points work), and the card's "under 1 GB" skip doesn't
  apply to it.
- When that drive is missing, it stays on the card as missing.
- A removable drive may show its health as "Unknown".
- While on the fallback, the fallback's drive is the one watched.

## 4. Events, logs, banners and Maintenance

**Events are decided on the server.** Today the page compares one `/stats` reading with the next, so nothing is
caught when no page is open, and each open page decides on its own.
- Each event has an id, a time, a type, a severity (`info`, `warn` or `flag`), a key for suppressing repeats, and
  its data.
- **Ids keep increasing, even across restarts.** An id is the larger of the current time in milliseconds since
  1970 and the last id plus one, so a clock that steps backwards can't reuse or reorder them.
- Repeats of the same key within 10 minutes are suppressed. The last 200 events stay in memory.
- **A page shows banners only for new events.** It replays nothing on load.

**One writer.**
- Any thread may raise an event or an error: either sampler, the web server, or the C# network tracer through the
  fast sampler. Raising one only adds it to a shared queue, passed to every runspace the way `$state` is today.
- The main loop drains the queue between requests:
  1. assigns the ids
  2. applies repeat suppression and the error throttle
  3. appends to the files, one writer per file that others can read
  4. publishes the in-memory events as a new array each time
- The array `/stats` reads is never changed in place, so serializing it can't fail with "collection was modified".

**The starting set of events** (later features add their own):

| Event | Severity | Banner | Logged |
|---|---|---|---|
| A player joins or leaves; a Plex stream starts | info | yes | no |
| Valheim or Plex goes offline or comes back; a status query stops answering | warn | yes | yes |
| Windows is waiting to restart | info | no | yes |
| A drive's health changes; the data drive goes missing | flag | yes | yes |
| The data folder fell back to the local one; a share appeared on the data folder | flag | yes | yes |
| A history save failed | warn | yes | yes |
| A sampler error; a background worker stopped | warn | no (status line) | yes |
| Maintenance on or off; SRRVRR started or stopped (with the reason) | info | no | yes |

Player names, Plex user and device names, and stream titles stay in memory for the live banner. Logs get counts
only.

**The event log:**
- `logs\events-YYYY-MM-DD.jsonl`, dated by local time, with one JSON object per line.
- Kept `LogRetentionDays` days (default 31).

**Cleanup (both logs):**
- It runs after startup and once a day.
- It deletes only regular files (not links or junctions) directly in the active `logs\` folder whose names match
  `^(events|srrvrr)-\d{4}-\d{2}-\d{2}\.(jsonl|log)$`.
- Age comes from the date in the name.
- The newest 7 days of files are never deleted.
- It's skipped, with an error-log line, if the clock is earlier than the newest file's date or more than
  `LogRetentionDays` past it. A wrong clock can then never wipe the logs.

**The crash and error log:**
- `logs\srrvrr-YYYY-MM-DD.log`: startup steps, settings problems, sampler errors (today these appear only on screen)
  and failures of the background workers.
- **The script's `trap`** writes the full exception: type, message, script line and stack.
- **A watcher for the background workers:** the main loop checks each worker's state once a second. A worker that
  has failed or ended logs its reason and errors, shows on the status line, and SRRVRR exits with a crash code, so
  whatever started it starts it again.
- **The network tracer (C# inside the script) can't run a PowerShell handler on its own thread.** So it keeps the
  last error's text and type, an error count and a "thread alive" flag. The fast sampler logs whenever the count
  changes or the thread stops.
- The last line says why SRRVRR stopped, with its exit code. A hard process death (killed, or out of memory) can't
  write that line; whatever started SRRVRR records the exit code instead.
- The same error is written at most once a minute, with a count of repeats.

**The daily cap (both logs):**
- Each day's file stops growing at 20 MB, with one line saying so.
- `flag` events and the final "stopped" line are still written past the cap: they're rare and small, and they're
  what the log is for.

**Banners:**
- The Valheim and Plex banners move from the page's own comparisons to server events.
- Sound stays a per-browser toggle.

**Maintenance:**
- A checkbox on the page, kept on the server, so it applies to every browser.
- **The request:** `POST /maintenance` with a JSON body `{"on": true}` or `{"on": false}`.
- **How long it lasts:** turning it on lasts `MaintenanceHours` (default 2), and it switches itself off after that.
  The longest allowed is `MaintenanceMaxHours` (default 8).
- **While it's on:** no banners and no dings anywhere. Events are still detected and logged, marked
  `"maintenance": true`.
- **On the page:** "Maintenance until HH:MM". The server sends the end time as `untilMs` (milliseconds since 1970),
  and the browser shows it in its own time.
- **Restarts:** it's saved to `state\maintenance.json`, so a restart in the middle of maintenance doesn't set off
  alerts.
- **Logging:** each change is logged with the requesting address.
- **Rate limit:** at most one change per address per 10 seconds, and 60 a day. Others get 429 and are counted, not
  logged one by one, so the log can't be flooded.
- **Who can tick it:** any device that can open the page. This release accepts that: it only silences alerts, and
  every change is logged with its address. v0.8.0 limits it to named PCs.

**The Flagged list** shows the logged events of the last 31 days from `/events`, newest first.

## 5. Stopping, and the exit codes

**Graceful stop.** Today `-Stop` force-stops the process, so the history save and the "why it stopped" line never
run.

**The stop event:**
- SRRVRR waits on a named Windows event tied to its own folder, so each copy answers to its own name.
- The name is `SRRVRR-stop-` plus the first 16 hex characters of a SHA-256 of the folder's path.
- That path is normalized the same way on both sides by one shared function:
  - mapped drive letters replaced by their network path
  - the full path in long names
  - no trailing `\`
  - upper case

**Elevated, as administrator or SYSTEM:**
- The event is `Global\SRRVRR-stop-<hash>`.
- Its permissions let only SYSTEM and Administrators signal or change it.

**Unelevated (a test copy):**
- The event is `Local\SRRVRR-stop-<hash>`.
- Its permissions let only the current user signal it.

**A name someone else got to first:**
- Any local user can create a named event, so SRRVRR checks it got a new one.
- If the event already exists, SRRVRR reads its owner and permissions.
- Unless the owner is SYSTEM or Administrators (or, unelevated, the current user) and nobody else can signal it,
  SRRVRR logs it and refuses to start (exit 3).

**What signals it:**
- `-Stop` and `Stop SRRVRR.bat` try the `Global\` name, then the `Local\` one, opening the event with signal rights
  only.
- On "access denied" they relaunch themselves elevated, as `-Stop` does today.
- Before signalling, the stopper writes `state\stop-requested` with the time and who asked.

**What SRRVRR does:**
- It checks the event in the request loop, and also between startup steps, so a stop that arrives during the
  15-17 s startup takes effect at the next step.
- On the signal: save history and Maintenance, log "stopped: requested", close the listener, exit 0.
- **Ctrl+C** takes the same clean path and logs "stopped: Ctrl+C", exit 0.
- **Closing the console window** is a hard stop. Up to 5 minutes of history and the last log line can be lost, and
  the README says so.

**If it doesn't stop:**
- The stopper waits about 10 seconds, then force-stops the process.
- It matches only a process whose `-File` argument resolves, by the same rules, to this folder's `SRRVRR.ps1`.
- A forced stop leaves a crash-looking exit code. That's why the `stop-requested` marker exists (below).

**Scope:**
- `-Stop` stops only the copy in its own folder.
- To stop a test copy, run the test folder's `Stop SRRVRR.bat`.

**Exit codes** for a normal start (not `-Stop`), for whatever starts SRRVRR (a boot launcher or a scheduled task):

| Exit code | Meaning | Start it again? |
|---|---|---|
| 0 | Clean stop (requested, or Ctrl+C) | No |
| 2 | Settings error | No: it would fail again the same way |
| 3 | Refused to start: data folder on a share, its permissions can't be fixed, another copy holds the data folder, or the stop event's name is taken | No |
| Anything else | Crash | Yes: up to 3 times in 10 minutes, then the launcher stops trying and logs it |

- A launcher treats any exit within 60 seconds of a `state\stop-requested` marker as a requested stop, doesn't
  restart, and deletes the marker.
- **How the codes are produced:**
  - Settings validation throws a settings exception, which the `trap` turns into exit 2.
  - The refusals throw a refusal exception, which becomes exit 3.
  - Anything else exits 1.
  - Both exception types are small C# classes, so the trap can tell them apart.

**Test builds** run from their own folder, outside the live install.
- `-Stop` recognizes a test build by its folder, not its file name.
- Each copy manages only its own firewall rules: "SRRVRR" and "SRRVRR (blocked)" for the live copy, "SRRVRR (test)"
  and "SRRVRR (test, blocked)" for a test copy, each also in its own firewall rule group. A copy deletes only rules
  in its own group, so an elevated test copy can't replace the live copy's rules.
- Only the live copy removes the rules left from SRRVRR's old name ("System Monitor").
- An unelevated copy listens on `localhost` only, as today, so only the machine it runs on can open it.
- A test build sets its own `DataPath` or leaves it empty (section 3's lock refuses a shared one anyway).

## 6. Settings

New settings, in `SRRVRR.config.example.psd1` with comments. They're validated at start; an invalid value is one
plain message and exit code 2.

| Setting | Default | Allowed |
|---|---|---|
| `DataPath` | `''` (SRRVRR's own folder) | A full local path with a drive letter; not a network path. Whether it exists isn't a settings error: a missing or read-only folder falls back (section 3). |
| `LogRetentionDays` | `31` | A whole number from 7 to 366 |
| `MaintenanceHours` | `2` | 0.25 up to `MaintenanceMaxHours` |
| `MaintenanceMaxHours` | `8` | 1 to 24 |

No settings are retired.

## 7. Testing and rollout

**Pester 5 tests:**
- **Counter math,** with fake samples.
- **History:**
  - the ring buffer wrapping around
  - saving and loading
  - stale, damaged, oversized and unknown-version files
  - the gap after a restart
- **Events and logs:**
  - ids strictly increasing, including two events in one millisecond and a clock stepping back
  - repeat suppression
  - cleanup: only matching old files, never links, the 7-day floor, a bad clock
  - the log line format, the error throttle and the daily cap (including flags written past it)
  - the single writer under events raised from several runspaces
- **Maintenance:** expiring; surviving a restart; the end time held to the maximum; the rate limit.
- **Web:**
  - the host allowlist and the origin check, including a DNS-rebinding request and a request with no `Origin`
  - the static path table, with traversal attempts returning 404
  - method rules
  - the `/events` and `/stats?since=` limits
- **Data folder:**
  - the share check: above, equal, below, a hidden share counting, special shares ignored, network paths, the
    share list unreadable
  - the lock file
  - the permissions fix
  - the fallback
- **Stopping:**
  - the folder hash normalization
  - a taken stop-event name refusing with exit 3
  - the exit codes from the trap
- **The page:** a parity check that `/stats` keeps every field of v0.6.0, and that the page served from `web\` matches
  the old one.

**CI** runs `tools\Invoke-Checks.ps1` on every PR:
- Every step runs with `shell: powershell` (Windows PowerShell 5.1, not PowerShell 7).
- Pester 5 and PSScriptAnalyzer are installed at exact versions, and the script starts with
  `Import-Module Pester -RequiredVersion <x>`. Windows PowerShell's built-in Pester 3.4 can't be picked up by mistake.
- The parse step also compiles each `Add-Type` block.
- It's advisory at first and becomes required once it has passed on three PRs in a row.

Locally, before every PR: the same script, plus `tools\Measure-SRRVRR.ps1` against the test build.

**Stacked PRs,** one per story, each with its CHANGELOG entry and README updates:
1. **#47 Foundation, no change in behavior:**
   - `Counters.psm1` and `Web.psm1`
   - tests and CI
   - the page moved to `web\`, with the static path table
   - `.gitattributes` and `.gitignore`
   - `tickMs` and the measuring tool
2. **#48 Running safely:**
   - `DataPath`, with its fallback, the share check, the lock and the permissions
   - the crash and error log, with the worker watcher
   - the graceful stop and the exit codes
   - test builds by folder, with their own firewall rules
   - the data drive on the drives card
   - the README's `-Stop` and test-copy text
3. **#49 History:** `/history`, saving, and the 15-minute button.
4. **#50 Events:**
   - the event log, its index and cleanup
   - server-side banners
   - Maintenance
   - the Flagged list
5. **#51 README: running SRRVRR at boot.** It may merge any time after #48.

History needs #48's graceful stop to save on shutdown, which is why it comes second.

**UAT per PR,** about 15 minutes, on a test build in its own folder on port 8091 with its own config. For example:
- Refresh the page on two PCs: the graphs start full.
- Restart SRRVRR: the history comes back, with a gap.
- Tick Maintenance: no banners, and the log is marked.
- Damage the state file: it's renamed `.bad`.
- Force an error: it's in the log.
- Make the data folder read-only, or remove a spare removable drive holding it: SRRVRR falls back, with a flag.
- Stop it: the log says "stopped: requested", with exit code 0.
- Create the stop event's name first as an ordinary user: SRRVRR refuses, with exit 3.
- Share a folder below the data folder: SRRVRR refuses, with exit 3.
- Point a test build at the live data folder: it refuses, with exit 3.

**Release:** v0.7.0 once #47 to #51 are merged. Then the boot launcher's own release carries it. That release must
be installed before v0.7.0 runs at boot, since until then the launcher checks only `SRRVRR.ps1` and the new
`modules\` and `web\` files would load unchecked.

**Rollback:** reinstall the previous release. The saved files are versioned, so an older SRRVRR ignores a newer
file rather than crashing on it.

## 8. Security

- **Who can talk to it:** the firewall stays local-network only, as today, with rules named and grouped per copy
  (section 5).
- **Every request's `Host` must be one of the server's own names or addresses,** on the configured port. That
  means:
  - its computer name and full DNS name
  - its own IPv4 and IPv6 addresses
  - `localhost`, `127.0.0.1` and `[::1]`

  Anything else gets 421 and nothing more. This stops a website a LAN user visits from reaching SRRVRR through a
  DNS-rebinding trick.
- **`POST /maintenance` is the only request that changes anything.** It requires the header `X-SRRVRR: 1`,
  `Content-Type: application/json`, and an `Origin` whose host and port are in that same list. A request with no
  `Origin` is refused. A browser can't send that header cross-site without a preflight, which SRRVRR never answers
  with permission.
- **Static files** are served from a fixed table, never from a path built from the URL (section 1).
- **Request sizes are bounded:** `/events` and `/stats?since=` (section 2), and the Maintenance rate limit
  (section 4).
- **What the logs hold:**
  - They never hold player names, Plex user or device names, titles, or the names of files on the shares.
  - They do hold counts, addresses (for Maintenance changes), SRRVRR's own paths, settings errors and exception
    details.
  - Logs stay on the server, writable only by SYSTEM and Administrators (section 3).
- **Code loads only from SRRVRR's own folder:** modules, the page, and the temperature library. An install that
  checks file hashes before start should cover `modules\`, `web\` and the library's DLLs as well as `SRRVRR.ps1`.
- **The stop signal** can't be taken over: SRRVRR checks the event's owner and permissions (section 5).
- **Data never goes on a share,** and only one copy uses a data folder (section 3).

## 9. Details pinned during test planning

Settled so the tests in `docs/plans/2026-10-29-srrvrr-core-test-plan.md` have one right answer:
- **Which copy is a test copy:** `tools\New-TestBuild.ps1` writes a `TESTBUILD.txt` marker into the test folder. A copy
  with that file uses the test firewall names and group.
- **UAT on one machine:** routine UAT uses two browsers on the server. An elevated test copy, with its own rules, is
  started only for steps that need another PC.
- **The host allowlist:**
  - A name with a trailing dot is refused.
  - IPv6 zone ids are stripped before comparing.
  - The list is rebuilt once a minute in the slow sampler, so an address change is picked up.
- **Cleanup boundary:** today counts as day 1, so a file dated exactly `LogRetentionDays` days ago is deleted, within
  the 7-day floor.
- **Crash-log line:** `yyyy-MM-ddTHH:mm:ss.fff+hh:mm LEVEL source: message`, one line per entry, with newlines
  escaped.
- **History from the future** (the clock stepped back): ignored like a stale file, not renamed.
- **A damaged or oversized `maintenance.json`:** renamed `maintenance.json.bad`, with Maintenance off and one error
  line.
- **`/events` without `days`:** 400. The page asks for `min(31, LogRetentionDays)` days, which `/stats` reports.
- **The lock comes first:** a second copy that finds `state\srrvrr.lock` held refuses (exit 3) even if the folder
  also looks read-only to it. It never falls back.
- **`?since=` with more than 50 newer events:** the 50 just after the id, with `eventsTruncated: true`. An id older
  than everything in memory counts as unknown and returns the newest 50.
- **Maintenance rate-limit counters:** kept in memory, reset at local midnight and on restart.
- **Ctrl+C on Windows PowerShell 5.1:** when a console is attached, SRRVRR reads Ctrl+C as a key
  (`[Console]::TreatControlCAsInput`) in the request loop it already runs every 50 ms. It can then save and exit 0,
  not depend on PowerShell's break handling. This is the first thing #48 proves.
- **Tool versions:** the newest stable Pester 5.x and PSScriptAnalyzer 1.x when #47 is built, pinned once at the top
  of `tools\Invoke-Checks.ps1` and in the workflow.

## Dependencies

What this release relies on, and what relies on it. Install-specific details (paths, hostnames, accounts, how a
particular launcher works) are kept in the owner's private records, not here.

**Relied on by:**
- **A boot launcher that checks SRRVRR's files before starting it.** It should:
  - check every file in `modules\` and `web\`, and the temperature library's DLLs by their pinned hashes;
  - refuse unlisted files, except the config and, when they're in SRRVRR's own folder, `state\` and `logs\`;
  - restart only on crash codes, up to 3 times in 10 minutes, honoring the `stop-requested` marker;
  - use the stop signal;
  - keep its own SRRVRR log for 31 days, the same as SRRVRR's logs.

  The entry script's path and command line don't change.
- **Anything that reads `/stats`** (for example, a network check that only confirms it's JSON):
  - Every field stays.
  - The request's host must be one of the server's own names or addresses (section 8).
- **The README's update steps** ("replace only ...") change to "replace the code folders" (#51). The README's
  `-Stop` and test-copy text changes in #48.

**Relies on:**
- **Windows PowerShell 5.1,** C# 5 in `Add-Type`, `HttpListener`, CIM (`Win32_Share`, `Win32_Volume`) and Windows'
  named events.
- **Pester 5 and PSScriptAnalyzer:** in CI, and locally where installed.
- **A local drive for `DataPath`** that isn't shared on the network, if one is set.
- **The firewall,** for the per-copy rule names and groups.

## Not in this release
- **v0.8.0, the transfer monitor:** what's being copied to and from the shares, how fast, and the bottleneck.
  Unknown PCs get flagged, and write bursts get logged. Maintenance is limited to named PCs then.
- **v0.9.0 and later:** 24-hour history with zoom, the phone app, the drive-almost-full alert, and the rest of the
  backlog before 1.0.
