# SRRVRR on a workstation: GPU, memory and the AI server: design

Status: approved by the owner on 2026-11-26 (written the same day). The owner asked for the calls to be made for
them ("you make the calls to start"), so every row under [Decisions](#decisions) is a call made in this design, and
the owner approved them all, Q1's release order included. Builds on the v0.7.0 core design (`docs/specs/2026-10-28-srrvrr-core-design.md`), v0.8.0
(`docs/specs/2026-11-06-srrvrr-v0.8.0-design.md`) and v0.9.0 (`docs/specs/2026-11-07-srrvrr-v0.9.0-design.md`);
anything not said here is as those say. Install-specific details (the PC's name, its AI server's ports, the install
folder) are in the owner's private records, never in this repo.

## Contents
- [Goals](#goals)
- [Why it has this shape](#why-it-has-this-shape)
- [Decisions](#decisions)
- [1. The workstation page](#1-the-workstation-page)
- [2. Roles and the host name](#2-roles-and-the-host-name)
- [3. Video memory and the GPU](#3-video-memory-and-the-gpu)
- [4. Memory](#4-memory)
- [5. Top programs](#5-top-programs)
- [6. The AI server](#6-the-ai-server)
- [7. Alerts](#7-alerts)
- [8. Designed for side by side, and the phone](#8-designed-for-side-by-side-and-the-phone)
- [9. Data sources and what they cost](#9-data-sources-and-what-they-cost)
- [10. Settings](#10-settings)
- [11. Contract changes](#11-contract-changes)
- [12. Admin](#12-admin)
- [13. Testing, budgets and rollout](#13-testing-budgets-and-rollout)
- [Agent team](#agent-team)
- [Dependencies](#dependencies)
- [Not in this release](#not-in-this-release)
- [Proposed stories](#proposed-stories)

## Goals

In the owner's words (2026-11-26): run "an instance of it on" the dev PC; "instead of those processes for the
server, I'd like it to have all the gpu and ram monitoring stats and a proposal of what might make sense for the AI
server" there; "eventually I'd like to have these side by side in the same app in some way, so let's design with the
end in mind"; "I'd like my phone to be able to see the stats of either eventually, but only local display to start
is fine". What it's for: "a bit of both", that is, keeping an eye on long AI jobs, and knowing whether the AI server
is still holding the graphics card (before playing a game, say).

The dev PC's page answers three questions:
- **Is the graphics card's memory full, and who holds it?** Video memory in use, whether it is spilling into system
  RAM, and the programs holding the most.
- **Is memory under pressure?** RAM, committed memory against its limit, paging from disk, and the WSL virtual
  machine's memory against its cap.
- **What is the AI server doing?** Off, starting, idle or working; how many jobs are queued and for how long; when
  the last batch finished; how much video memory it holds.

Scope stays ops health: is it up, is it struggling, is it about to break. SRRVRR watches and reports; it never starts,
stops or changes anything.

## Why it has this shape

- **One SRRVRR, not a second app.** The counters, the GPU pick, history, events, banners, the page and the tests
  already exist; the backlog already planned "SRRVRR safe on a non-server PC". A second app would mean two codebases
  agreeing on a data format forever.
- **Each PC runs its own copy.** A web page can't read the viewing PC's hardware (backlog, 2026-10-29), so the
  numbers have to come from SRRVRR running on that PC. Each copy owns its own data, alerts and history.
- **Local display first.** Running without administrator, SRRVRR listens on `localhost` only and makes no firewall
  rule, so nothing on the network changes in this release. The phone needs that to change, later (section 8).
- **The AI server is local-only by design.** Its UI listens on `127.0.0.1` with no login. SRRVRR on the same PC can
  read two read-only status endpoints from it; it must never relay anything to it, or SRRVRR's page would become a
  way into the AI server once the page is reachable from the network.
- **Spilling is the signal that matters most on this PC.** When a graphics card's own memory is full, NVIDIA's
  Windows driver can move the overflow into system RAM ("shared GPU memory") instead of failing. Work keeps running,
  several times slower, with no error anywhere. On the dev PC, shared GPU memory measured 92 MB at idle
  (2026-11-26), so a jump past 1 GB while the card is nearly full is a clear sign.

## Decisions

Calls made in this design on the owner's instruction, numbered Q1 to Q12 (this spec's own) so they don't clash with
the cross-repo items (D15 to D19) under [Dependencies](#dependencies). Each says what was rejected.

| # | Question | Call |
|---|---|---|
| Q1 | **When it ships.** It was planned with the phone in v0.11.0, after 24-hour history (v0.10.0). | **Next, right after v0.9.0's four PRs merge, as v0.10.0.** The owner called it a key feature, it doesn't depend on history, and it is the PC half of the phone-and-PC release. 24-hour history moves to v0.11.0, and the phone with side by side to v0.12.0. The owner confirms the milestones. |
| Q2 | **How a copy knows it's on a workstation.** | **A `Role` setting: `'Server'` (the default, today's page exactly) or `'Workstation'`.** *Rejected:* a switch per card (more settings, and a later page showing two hosts needs to know each host's kind), and guessing from what's installed (breaks the day Plex is installed on a PC). |
| Q3 | **What the Workstation role turns off.** | **The Processes card and its readers (Valheim, Plex, the per-process network tracer), the Transfers card and its SMB readers, and their events.** Kept: the CPU, Memory, GPU and Network tiles, Storage and its alerts, Restart pending, Flagged, Maintenance, history and sound. *Rejected:* the backlog's "Processes rows only for what's installed": the owner asked for GPU and memory instead. |
| Q4 | **The name on the page.** | **The header and the tab title show `DisplayName`. Its default is `SRRVRR` on the Server role, so the server's page is unchanged by construction, and the computer's name on the Workstation.** This narrows the 2026-10-22 decision (header hardcoded): the Server keeps it; with two copies, the Workstation's name is how they're told apart. *Rejected:* the computer's name on both roles, which would change the header of any server not named SRRVRR. |
| Q5 | **Video memory.** | **A new Video memory tile on the Workstation: dedicated memory in use of the card's total, with a graph, shared memory as a second line, and a "Spilling into RAM" badge.** Spill rule in section 3. The thresholds are fixed values, not settings. |
| Q6 | **GPU detail.** | **Power, power limit, clock, fan and throttle reasons, added to the `nvidia-smi` call SRRVRR already makes every 5 seconds for temperature.** NVIDIA only, as the temperature is (decision 2026-10-22). |
| Q7 | **Memory detail.** | **Committed memory of its limit, paging from disk, and the WSL virtual machine's memory of its cap,** on the Memory tile's lines (section 4). |
| Q8 | **What replaces the Processes card.** | **A Top programs card: up to 8 programs, the 5 holding the most video memory and the 5 using the most RAM, sorted by video memory.** Columns: program, video memory, RAM, CPU. Every 5 seconds. *Rejected:* a fixed list of programs (the owner's heavy programs change: games, the AI server, browsers). |
| Q9 | **What the AI server card reads.** | **ComfyUI only, from the `ComfyUi` setting (a name and a port on `127.0.0.1`), with exactly two read-only requests every 5 seconds: `GET /system_stats` and `GET /prompt`.** *Rejected:* `/queue` and `/history` (they hold the prompts), ComfyUI's websocket (it gives step-by-step progress but also carries preview images), and anything run inside WSL (calling `wsl.exe` starts the distro and its memory). |
| Q10 | **New alerts.** | **"AI job finished" (a banner, not logged), "AI server stopped answering during a job" (amber, logged), and "Video memory spilling into RAM" (amber, logged) with its end (logged, no banner).** Section 7. |
| Q11 | **Administrator on the dev PC.** | **Not in this release.** SRRVRR runs unelevated there: the page is at `http://localhost:<port>` only, and the CPU and memory temperatures show "Temp n/a" (they need administrator). Everything else in this spec works unelevated, including the GPU temperature and the Network tile, whose counters need no administrator (README "Administrator vs. not"). Elevating it creates a firewall rule on that PC, which is the owner's call, and belongs with the phone (section 8). |
| Q12 | **Job progress ("step 12 of 30").** | **Not in this release.** It needs the websocket (Q9). The owner is at the PC for now and ComfyUI's own page shows progress. The card shows how long the queue has been working instead. Revisit with the phone. |

## 1. The workstation page

The same page, laid out by role. A sketch at desktop width (values are examples):

```
DEV-PC   Up 2 days, 3 hours   v0.10.0          Connected  [60 s][15 min]  [Sound off]  [ ] Maintenance

+- CPU --------+ +- Memory -----+ +- GPU --------+ +- Video memory -+ +- Network ----+
| 12%          | | 38%          | | 97%    71 C  | | 17.8 / 24 GB   | | 1.2 Mb/s     |
| Core i7-...  | | 24.1 / 64 GB | | 312 of 450 W | | shared 0.1 GB  | |              |
| [graph]      | | [graph]      | | [graph]      | | [graph]        | | [graph]      |
+--------------+ +--------------+ +--------------+ +----------------+ +--------------+

+- AI server ----------------------------------------------------------------------------+
| Main      Working   2 queued, for 6 min      holds 15.2 GB    last done 7:42 PM, 14 min |
| Second    Off                                                                           |
| WSL VM    31.2 of 48 GB  [===============-----]                                         |
+----------------------------------------------------------------------------------------+
+- Top programs ------------------------ Video memory ------ RAM -------- CPU -----------+
| WSL VM                                  17.6 GB             31.2 GB      4%             |
| dwm                                      3.3 GB              0.2 GB      1%             |
| firefox (14)                             0.7 GB              3.1 GB      2%             |
| As Task Manager counts it: programs share some video memory, so these add up to more.  |
+----------------------------------------------------------------------------------------+
+- Storage ---+  +- Flagged ---+   (as today)
```

- **Tiles:** five on the Workstation (Video memory added between GPU and Network). Tiles keep their size; the row
  wraps, and at phone widths they stack, as today.
- **Memory tile, Workstation only:** a third line, "Committed 31 of 96 GB, paging 0 MB/s" (section 4).
- **GPU tile, Workstation only:** its second line becomes "312 of 450 W, 2,610 MHz, fan 48%", with an amber badge
  when the card is held back: "Power limit", "Hot" or "Slowed" (section 3).
- **AI server card:** hidden when `ComfyUi` is empty. **Top programs:** always shown on the Workstation.
- **The Server role's page is unchanged:** its header shows `DisplayName`, which defaults to "SRRVRR" there (Q4).

## 2. Roles and the host name

- `Role` is read once at startup. The startup log says which, and what that turns off, e.g. "Role: Workstation.
  Off: Processes, Transfers. On: video memory, top programs, AI server".
- **Turned off means not run,** not just hidden: on the Workstation the Valheim and Plex readers, the per-process
  network tracer and the SMB readers never start, so they cost nothing and don't need administrator. Their settings
  (`Processes`, `ValheimPort`, the v0.9.0 transfer settings) are still validated, then ignored, with one startup line
  saying so.
- **The Workstation-only readers** (sections 3 to 6) don't run on the Server role either.
- `/stats` always carries `hostName` (the `DisplayName`) and `role` (`'server'` or `'workstation'`). The page uses
  `role` to pick its cards and `hostName` for the header and the tab title.
- The roles and what each runs are one table in the code, so the next card added picks its roles in one place.

## 3. Video memory and the GPU

**Video memory, every second,** from the `GPU Adapter Memory` counter category the fast loop already reads for the
chosen GPU: `Dedicated Usage` (already shown) and `Shared Usage` (new; same read, so no added cost). The card's
total is the one SRRVRR already knows from the GPU pick.

**The spill rule.** Spilling starts when dedicated use is at least 95% of the card's memory **and** shared use is at
least 1 GB, both for 10 seconds in a row. It ends when dedicated falls below 90% **or** shared falls below 0.5 GB,
for 30 seconds in a row. The gap between start and end values stops it flickering. While spilling, the tile shows
an amber "Spilling into RAM" badge and the shared line turns amber; the event is in section 7. Not confirmed yet:
whether the driver's fallback also applies to work inside WSL (the AI server). Story 2's UAT checks it if the owner
chooses to load a large model. If it doesn't apply there, the rule still catches Windows programs, and the AI server
shows its own trouble as a job ending early.

**GPU detail, every 5 seconds,** from the one `nvidia-smi` call the slow sampler already makes for the temperature,
with more fields: `power.draw`, `power.limit`, `clocks.sm`, `clocks.max.sm`, `fan.speed`, `pstate`, and the
throttle reasons as named yes/no fields: `clocks_event_reasons.sw_power_cap`, `.hw_slowdown`,
`.sw_thermal_slowdown`, `.hw_thermal_slowdown`, `.hw_power_brake_slowdown`. Newer drivers call these
`clocks_event_reasons`, older ones `clocks_throttle_reasons`: try the first, fall back to the second once, and log
which. Measured on the dev PC (driver 621.24, 2026-11-26): both names work, and the whole call took 63 ms. The badge:
"Power limit" for either power reason, "Hot" for either thermal reason, "Slowed" for hardware slowdown. Idle and
application-clock reasons are ignored. A field the driver reports as `[N/A]` is left out, not shown as zero.

**History:** the two video memory lines join the 15-minute history the same way the other graphs do (section 11).

## 4. Memory

On the Workstation, from the `Memory` counter category, read with the existing whole-category reader:
- **Committed of the commit limit:** `Committed Bytes` of `Commit Limit`. Amber at 90%, because programs fail to get
  memory at 100%. Measured on the dev PC: 31 GB of 102 GB.
- **Paging from disk:** `Pages Input/sec` times the page size, as MB/s. Shown as a number, with no colors.
- **The WSL virtual machine:** the memory held by the `vmmemWSL` process (its working set), against the cap. The cap
  is `memory=` under `[wsl2]` in the `.wslconfig` of the account SRRVRR runs as, read at startup and every 60 seconds.
  With no file or no `memory=` line, the cap is WSL's default, half of physical memory, and the hover says "default".
  Amber at 90% of the cap, since WSL then starts swapping inside the VM. With no `vmmemWSL` process: "not running".
  Shown on the AI server card's last row (section 6), or on the Memory tile's hover when no AI server is configured.
  Not confirmed yet: that an unelevated process can read `vmmemWSL`'s working set. Story 3 checks it with the AI
  server running. If it can't, the row says "WSL VM: running" without a number.

## 5. Top programs

- **Every 5 seconds, in the slow sampler.** Per-program video memory from the `GPU Process Memory` category
  (`Dedicated Usage` per process id; measured on the dev PC at under 1 ms, 45 processes). RAM is the private working
  set, the same measure as the old Processes rows (decision 2026-10-22). CPU is the share of all cores over those 5
  seconds.
- **Grouped by program name,** like the Processes rows: every `firefox` process is one row, with its count in
  brackets. `vmmemWSL` is labeled "WSL VM".
- **Rows:** the 5 programs holding the most video memory and the 5 using the most RAM; once overlaps are merged,
  that's up to 8 rows, sorted by video memory, then RAM.
- **The numbers overlap:** programs share some video memory, so the rows add up to more than the card's total (on
  the dev PC, `dwm` alone showed 3.3 GB while the card had 1.7 GB in use). The card says so in one line and shows no
  total. The UAT checks the numbers against Task Manager's Details tab.
- **Where the AI server's video memory shows up** (as `vmmemWSL`, a `dxg` process, or not at all per process) is not
  confirmed yet. Story 3 checks it with the AI server running, and the card's labels follow what's found.

## 6. The AI server

**What it reads.** For each entry in `ComfyUi`, every 5 seconds, in the slow sampler, with a 2-second timeout and a
256 KB limit on each reply:
- `GET http://127.0.0.1:<port>/system_stats`: from it SRRVRR keeps only `system.comfyui_version` and, for the first
  device, `vram_total`, `vram_free`, `torch_vram_total` and `torch_vram_free`. Everything else in the reply
  (`argv`, paths, Python and library versions) is dropped at the reader.
- `GET http://127.0.0.1:<port>/prompt`: SRRVRR keeps only `exec_info.queue_remaining`, which counts the running job
  and those waiting.

The setting holds only a port: the host is always `127.0.0.1`, so SRRVRR can't be pointed at another machine. SRRVRR
never makes any other request to the AI server, never sends anything but these two GETs, and never relays a request
from its own page. The exact field meanings are confirmed against the AI server's pinned ComfyUI version in story 4,
from a recorded reply.

**States, per entry:**

| State | When | Shown |
|---|---|---|
| Off | No answer, and no WSL VM running | Gray "Off" |
| Starting | No answer, the WSL VM is running, and this entry hasn't answered since the VM started | Gray "Starting" |
| Idle | Answers, queue 0 | Green "Idle", and "holds 15.2 GB" |
| Working | Answers, queue 1 or more | Accent "Working", "2 queued, for 6 min", "holds 15.2 GB" |
| Not answering | No answer 3 times in a row (15 s), after answering since the VM started, with the VM still running | Amber "Not answering" |
| Unknown | Answers, but the reply isn't what's expected | Gray "Unknown reply" (logged once) |

- One missed answer keeps the last state, so a slow reply during a model load doesn't flicker.
- **"holds"** is `torch_vram_total`, the video memory the AI server's PyTorch has reserved. That number answers "is
  it still holding the card". The hover adds the card as the AI server sees it (`vram_total`, `vram_free`) and its
  ComfyUI version.
- **"for 6 min"** counts from the first reading with a queue of 1 or more, to now.
- **"last done 7:42 PM, 14 min":** when the queue last went from 1 or more to 0 after at least 60 seconds of work,
  and how long that took. Kept in memory only; a restart forgets it.
- **The WSL VM row:** section 4.
- When the VM can't be seen (section 4's fallback), Starting isn't shown: no answer is Off until the entry has
  answered once since SRRVRR started.

## 7. Alerts

New event types, added to the existing table (`modules/Events.psm1`, `$script:EventTypes`). Data is counts and the
owner's own configured names, never prompts, file names or model names.

| Type | Severity | Banner | Logged | When | Banner text |
|---|---|---|---|---|---|
| `ai-job-done` | info | yes | no | Working to Idle after at least 60 s of work | "AI job finished", "Main, took 14 min" |
| `ai-stopped-answering` | warn | yes | yes | Working to Not answering | "AI server stopped answering during a job", "Main" |
| `vram-spill` | warn | yes | yes | The spill rule starts (section 3) | "Video memory full: spilling into RAM", "Work on the GPU will be slow" |
| `vram-spill-ended` | info | no | yes | The spill rule ends | (Flagged list only) |

- `ai-job-done` fires once per batch: a queue of five jobs finishes with one banner when the queue empties. It isn't
  logged, so it doesn't fill the Flagged list (like `player-join`).
- Stopping the AI server on purpose during a job raises `ai-stopped-answering` if the VM stays up for 15 seconds after
  the UI stops. That's accepted and noted in the README.
- The existing drive alerts apply on the Workstation as on the server.
- Maintenance, sound and the 10-minute repeat rule work as today.

## 8. Designed for side by side, and the phone

The end state, which a later release builds: one page shows the server and the dev PC side by side, from either
PC or from the owner's phone on home Wi-Fi. This release builds none of that, but it must not block it. What it puts
in place:
- **Each host describes itself.** Every `/stats` has `hostName` and `role`, so a page that fetches another copy's
  `/stats` knows what it's looking at and which cards to draw.
- **Each copy stays the authority for its own host:** its own data, alerts, history and Maintenance. No copy stores
  another's data.
- **The new cards render from data passed in,** not from the page's globals: each new card is a function taking a
  container element and one host's `/stats`, so a second column later calls the same functions with the other host's
  data. The older cards are converted when side by side is built, not now.
- **Nothing in the new readers depends on being viewed locally.**

Left for that release, and recorded here so this one doesn't decide them by accident:
- **How the page gets the other host's data:** the browser fetches it directly (CORS limited to that one origin, the
  backlog's plan), or one copy relays it (simpler for the phone, but needs its own security review).
- **The phone reaching the dev PC:** SRRVRR elevated there with a local-network firewall rule, and the PC's VPN
  client set to allow local network traffic. Both are the owner's to apply.
- **HTTPS** for an installable phone app (mixed-content rules: an HTTPS page can't fetch plain-HTTP `/stats`).
- **Layout:** columns on wide screens, stacked or switchable on the phone.

## 9. Data sources and what they cost

| Data | Source | Where | Measured on the dev PC (2026-11-26) |
|---|---|---|---|
| Shared video memory | `GPU Adapter Memory`, already read | Fast loop | No new read |
| Power, clocks, fan, throttle | The existing `nvidia-smi` call, more fields | Slow sampler, 5 s | 63 ms for the whole call |
| Per-program video memory | `GPU Process Memory` category | Slow sampler, 5 s | Under 1 ms, 45 instances |
| Per-program RAM and CPU | `Process` category (whole-category read) | Slow sampler, 5 s | To measure in story 3 |
| Committed, paging | `Memory` category | Slow sampler, 5 s | To measure in story 3 |
| WSL VM memory | `vmmemWSL` process; `.wslconfig` | Slow sampler, 5 s; file every 60 s | To measure in story 3 |
| AI server | Two GETs per entry on `127.0.0.1` | Slow sampler, 5 s | To measure in story 4 |

Nothing slower than about 50 ms goes in the fast loop (`AGENTS.md`). A refused connection on `127.0.0.1` (AI server
off) returns at once; a hung one costs at most the 2-second timeout per request, and the PR reports the slow sampler's
worst pass time with the AI server off, idle and working.

## 10. Settings

New settings, in `SRRVRR.config.example.psd1` with comments and in the README's table. Invalid values stop SRRVRR with
one message (exit code 2), as for every setting.

| Setting | Default | Values |
|---|---|---|
| `Role` | `'Server'` | `'Server'` or `'Workstation'`, not case-sensitive (section 2). |
| `DisplayName` | `''` | `''` = `SRRVRR` on the Server role, this computer's name on the Workstation (Q4). Otherwise 1 to 32 characters: letters, digits, spaces, `-`, `_` and `.`. Shown in the header and the tab title. |
| `ComfyUi` | `@()` | Up to 4 entries, each `@{ Name = 'Main'; Port = 8188 }`: `Name` 1 to 20 characters (the same characters as `DisplayName`), unique; `Port` 1024 to 65535, unique, and not SRRVRR's own `Port`. Read only on the Workstation; on the Server it is validated and ignored, with a startup line. |

The spill thresholds, the 60-second "job" minimum, the 5-second interval and the timeouts are fixed values in the
code, documented in the README, not settings.

## 11. Contract changes

- **`/stats`, always:** `hostName` (string), `role` (`'server'` or `'workstation'`).
- **`/stats`, Workstation only** (names follow the existing flat style; units match their neighbours, e.g. `gpuMem`):
  - `gpuShared`, `gpuSpill` (true or false)
  - `gpuPower`, `gpuPowerLimit`, `gpuClock`, `gpuClockMax`, `gpuFan`, `gpuPState`, and `gpuLimits`: a list of
    `'power'`, `'thermal'`, `'slowed'`
  - `memCommit`, `memCommitLimit`, `memPageIn`
  - `wsl`: `{ running, mem, cap, capSource }`, where `capSource` is `'config'` or `'default'`
  - `top[]`: `{ name, count, vram, mem, cpu }`
  - `ai[]`: `{ name, state, queue, workingSec, holds, vramTotal, vramFree, version, lastDoneTs, lastDoneSec }`
- **The Server role's `/stats`** is v0.9.0's plus only `hostName` and `role`. A shape test proves it, against a new
  shape fixture taken from v0.9.0.
- **`/history`:** on the Workstation, two more lines (dedicated and shared video memory). An older version loading
  the file ignores lines it doesn't know, as v0.9.0's section 8 requires. 24-hour history (Q1: now v0.11.0) inherits
  these lines.
- **Events:** the four types in section 7. An older version shows an unknown type by its name.
- **Settings:** an older version warns about the three new settings and ignores them. A Workstation config run on an
  older version shows the server layout, with Processes rows "Offline", which is harmless.
- **The project map** records the new fields and the new reader of the AI server (D17).

## 12. Admin

What the owner can do with no AI session open:
- **Configure:** `Role`, `DisplayName` and `ComfyUi` in `SRRVRR.config.psd1`; restart SRRVRR after changing it.
- **Read the startup log,** which gains:
  - `Role: Workstation. Off: Processes, Transfers. On: video memory, top programs, AI server`
  - `Video memory: NVIDIA GeForce ... 24 GB, watching for spill (95% full and 1 GB shared)`
  - `nvidia-smi detail fields: clocks_event_reasons` (or `clocks_throttle_reasons`, or `none`)
  - `WSL VM: memory cap 48 GB (from .wslconfig)` or `(default: half of RAM)`
  - `AI server 'Main': ComfyUI on 127.0.0.1:8188, answering (ComfyUI 0.x.y)` or `not answering (off or starting)`
- **Read the daily log and the Flagged list** for `ai-stopped-answering`, `vram-spill` and `vram-spill-ended`, in the
  existing format.
- **A crash still writes the log before exiting** (core design). Reader failures are throttled `sampler-error`
  events, as today.
- **Install and update on the dev PC:** the README's new "Running on a workstation" section: copy the release files
  to a folder, copy the example config, set `Role = 'Workstation'` and the `ComfyUi` entries, start it with
  `Start SRRVRR.bat` and answer **No** to the administrator prompt, then open `http://localhost:8099`. Updating works
  as on the server (README "Settings"). The server keeps getting SRRVRR through the boot launcher's releases, as
  today.

## 13. Testing, budgets and rollout

**Tests** (ids added to the test plan, which the traceability test checks):
- **Pure functions, fully tested:** the role table (what each role runs); the spill rule (start, end, each threshold
  edge, the hold times, flicker); the throttle fields to badge; `nvidia-smi` CSV parsing (fields `[N/A]`, the
  fallback name); the `.wslconfig` reader (missing file, no `[wsl2]`, `memory=48GB`, `memory=48000MB`, comments,
  junk); top-programs grouping, the two top-5 lists merged and sorted; the AI server state machine (every
  transition in section 6, the one-miss hold, the VM fallback); job timing and `ai-job-done` once per batch; every
  new setting's validation.
- **Fixtures:** recorded `ReadCategory` output for `GPU Process Memory` and `Memory`, `nvidia-smi` lines, and the AI
  server's two replies, hand-checked, with made-up names. The `/system_stats` fixture puts a sentinel string in
  `argv` and the paths, and a test asserts it never appears in `/stats` or a log line.
- **A fake AI server** (a small `HttpListener` in the smoke tests) that answers, answers slowly, refuses, returns
  junk, returns a reply over 256 KB, and changes its queue count. The smoke tests drive the states through it.
- **Static checks:** the AI server reader's code contains no `wsl`, `/queue`, `/history`, `/ws`, `/view` and no
  request method other than GET; its host is the literal `127.0.0.1`.
- **The Server role:** the `/stats` shape test (section 11), and the existing tests pass unchanged with no `Role` set.
- **The page:** the new tiles and cards in each state, by role, in the existing JavaScript tests; the new cards'
  render functions are tested with a host's `/stats` passed in (section 8).

**UAT,** about 15 minutes per story, on a test build (`tools\New-TestBuild.ps1`) in its own folder on port 8091,
unelevated, on the dev PC (and for story 1 also on the server). Steps per story are under
[Proposed stories](#proposed-stories).

**Budgets.** The Server role, against v0.9.0's baseline (`tools\budgets.psd1`): no change beyond the existing
tolerances, measured on a server test build in story 1 and at release. The Workstation, measured on the dev PC with
`tools\Measure-SRRVRR.ps1`, recorded in `budgets.psd1` as a separate workstation baseline in story 1, and held by the
later stories: CPU at most 1% of the machine on average; private memory at most 25 MB above story 1's workstation
baseline; `/stats` p95 at most 30 ms; the page at most 150 ms; startup at most 20 s; the fast tick's median within
the existing tolerance of story 1's workstation baseline; the slow sampler's worst pass (`slowMs`) reported, idle and
with the AI server working; disk writes at most 100 MB a day.

**Release and rollout:** the release PR, tag and GitHub release as usual; the boot launcher's release carries it to
the server as usual, listing any new files. On the dev PC, the owner installs it by hand from the README section
(12) into the folder named in the private records. **Rollback:** on the server, the previous launcher release; on
the dev PC, stop it and copy the previous release's files back (section 11 is why that's safe).

## Agent team

- **Implementer:** one Claude Code session on Sonnet at medium effort, in this repo on the dev PC. It starts from
  this spec and the implementation plan, not from the chat that produced them, and reads only those, `AGENTS.md`,
  `docs/DECISIONS.md`, the README sections it changes, and the files the plan names. One PR per story, stacked, each
  with its CHANGELOG `[Unreleased]` entry, README update and decision line. It stops at every owner gate:
  - each UAT;
  - starting or stopping the AI server (the owner's; it holds the card and the RAM), including the one time the
    implementer needs real replies recorded as fixtures (story 4);
  - anything needing administrator: never run elevated, never touch the dev PC's firewall;
  - the server test build in story 1, staged as `AGENTS.md` says, run by the owner.
- **Reviewer:** one read-only review on Opus at medium effort, of stories 1 (the role gating and the Server role
  staying unchanged) and 4 (the AI server boundary: the two GETs, the dropped fields, no relay, no WSL). It reads
  this spec and the PR's diff, and writes findings to the PR.
- **Architect:** on the owner's request only.
- **Token estimate:** about 600k to 1M tokens on Sonnet over the five stories (SRRVRR's main script and page are
  large, and each story reads them), plus about 80k on Opus for the two reviews. No multi-agent workflows.

## Dependencies

Shown to the owner when work starts and before each merge.
- **D15 (ordering): v0.9.0 first.** Its design was approved on 2026-11-11 (on its spec branch, with every Q decided;
  older copies on the plan branch still say "pending"). Its four stacked PRs (#76 to #79) change the slow sampler,
  `/stats`, the page, the settings and the events. The implementation plan names the readers and settings to gate
  from the top of that stack, `feature/79-named-maintenance`. The implementer branches from `main` after the four
  merge, re-checks those names there, and takes the Server role's `/stats` shape fixture from that `main`.
- **D16 (the AI server project): two read-only endpoints.** SRRVRR reads `GET /system_stats` and `GET /prompt` from
  its UI on `127.0.0.1`. That project needs no change; its UI stays local-only. If it changes its ports, the owner
  updates `ComfyUi`. If a ComfyUI update changes those replies, the card shows "Unknown reply" until SRRVRR is
  updated.
- **D17 (the project map and the environment records): one story there.** A second SRRVRR on the dev PC (its port,
  unelevated, no firewall rule), the contract in D16, and the new `/stats` fields.
- **D18 (the boot launcher):** carries the release to the server as usual and lists any new files. Nothing changes
  on the dev PC's startup.
- **D19 (later, the side-by-side release):** a local-network firewall rule on the dev PC and the VPN client's local
  network setting (the owner applies both), and the CORS or relay and HTTPS choices (section 8). Not needed now.
- **The network test** reads `/stats`: only new fields are added, so it is unaffected.
- **Nothing else changes:** no new ports opened, no firewall rules, accounts or shares.

## Not in this release

- The phone, side by side, CORS, a relay, HTTPS (section 8).
- Running elevated on the dev PC: CPU and memory temperatures, and the page being reachable from other devices (Q11).
- Job progress, and anything about what the AI server is making: prompts, model names, file names, previews (Q9, Q12).
- Starting or stopping the AI server from the page.
- Starting SRRVRR at sign-in on the dev PC, or a starter that doesn't ask for administrator.
- Other AI apps (a local chat model is the AI server's own phase 2): the card is named "AI server" so a second
  reader can add rows later.
- GPU detail, video memory or top programs on the Server role; Transfers on the Workstation.
- Per-program GPU %, AMD and Intel detail.

## Proposed stories

One PR each, stacked in this order; each becomes one issue in the release's milestone once the owner approves. The
implementation plan lists the tasks and test ids.

| # | Story | UAT (on the dev PC unless said) |
|---|---|---|
| 1 | **Roles and the host name:** `Role`, `DisplayName`, `hostName` and `role` in `/stats`, the role table, the Workstation's readers off, the header and tab title, the page's cards picked by role, the render-from-data pattern for new cards, the workstation budget baseline, the README section | The test build shows the PC's name, no Processes or Transfers card, and the tiles, Storage and Flagged working; the console has no Valheim, Plex or tracer lines. **On the server,** a test build with no `Role` looks and behaves exactly like the live one. |
| 2 | **Video memory and GPU detail:** the Video memory tile and its history lines, the spill rule and its events, the `nvidia-smi` fields and the GPU tile's line and badge | During a game, the Video memory tile and the GPU line move, and the power and clock look like the game's own overlay or Task Manager. Optionally, with the AI server running, load the largest model and watch for the badge (section 3). |
| 3 | **Memory detail and top programs:** committed, paging, the WSL VM and its cap, the Top programs card | The Top programs rows match Task Manager's Details tab (Dedicated GPU memory, Memory (private working set)) to within about 10%. With the AI server running (owner starts it), the WSL VM row shows its memory and cap. |
| 4 | **The AI server card:** `ComfyUi`, the reader, the states, the job timer, `ai-job-done` and `ai-stopped-answering`, the boundary tests | With the AI server stopped, its rows say Off. Start it: Starting, then Idle within its usual start time, then "holds" after the first image. Queue a video job: Working, the count and the timer; when it ends, one "AI job finished" banner with the ding. Stop it: Off, and the Video memory tile drops back. |
| 5 | **Release and the dev PC install:** the release PR, the owner's install on the dev PC from the README, and the records story (D17) | The owner's install answers at `http://localhost:8099` and survives a restart of SRRVRR. |
