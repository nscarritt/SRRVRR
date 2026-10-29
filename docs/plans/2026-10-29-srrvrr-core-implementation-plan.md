# SRRVRR core (v0.7.0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the v0.7.0 core: modules with tests, the page in its own files, 15 minutes of server-side history,
server-side events with a 31-day event log and a crash log, Maintenance, a Flagged list, and a graceful stop with
exit codes, as five stacked PRs (#47 to #51).

**Architecture:** Module-first ("strangler"). `SRRVRR.ps1` stays the entry point and becomes the composition root:
it loads settings, wires real dependencies into modules loaded by full path, starts the runspaces and runs the
listener loop. All logic moves into `modules\*.psm1` as plain, injectable functions; the listener loop only copies
`Invoke-SrrRoute`'s result to the response and drains the event queue between requests.

**Tech Stack:** Windows PowerShell 5.1, C# 5 in `Add-Type`, `System.Net.HttpListener`, CIM, Pester 5,
PSScriptAnalyzer, plain JavaScript in `web\app.js` (tested with `node --test`), GitHub Actions on a Windows runner.

**Spec:** `docs/specs/2026-10-28-srrvrr-core-design.md`. **Test plan:** `docs/plans/2026-10-29-srrvrr-core-test-plan.md`
(test ids `T47-01` to `T51-10`, fixtures, fakes and helpers). Executors read all three: this plan says what to build
and in what order; the test plan says exactly what each test asserts.

## Global Constraints

- Windows PowerShell 5.1 only (never `pwsh` features); C# 5 inside `Add-Type`.
- `.ps1`, `.psm1`, `.psd1` and `.bat` files are pure ASCII; build symbols at runtime. `web\` files may be UTF-8.
- After every edit: parse the script and count non-ASCII lines (`tools\Test-Parse.ps1`, `tools\Test-Ascii.ps1`).
- Anything slower than about 50 ms belongs in the slow sampler, never the 1 s loop.
- Settings fail fast with one plain message (exit 2); retired settings go in `$retired`.
- Firewall stays local-network only; Windows networking and firewall calls go through `Invoke-Reported` with
  `-ErrorAction Stop`.
- No personal details in committed files: no IPs except documentation/private examples, no share paths, no hostnames
  other than "SRRVRR". `tools\Test-NoPrivateInfo.ps1` enforces it.
- Modules load only by full path from SRRVRR's own `modules\`; never by name; never `$env:PSModulePath`.
- No module calls the clock, `Write-Host`, `exit`, `$global:` or `[Console]` (test plan section 3.2, rules 1 and 6).
- Limits are parameters with the spec's defaults (test plan section 3.2 rule 8): ring 900, store 200, suppression
  10 min, throttle 60 s, daily cap 20 MB, stop wait 10 s, history max age 15 min, save every 5 min, `since` limit 50,
  `/events` limit 1,000, history read cap 2 MB, Maintenance read cap 4 KB, rate limit 10 s and 60 a day, cleanup
  floor 7 days, stop-requested window 60 s.
- Exit codes: 0 clean stop, 2 settings error, 3 refused to start, anything else a crash.
- Budgets (checked on every PR with `tools\Measure-SRRVRR.ps1`): process CPU <= 1% of the machine; private bytes
  within 25 MB of the previous release after 60 min; `/stats` p95 <= 30 ms (also under `/history` and `/events`
  load); `/history` and `/events` <= 50 ms; page load <= 150 ms; startup <= 20 s; tick median within 10% or 5 ms of
  PR 1's; disk writes <= 100 MB a day; UAT about 15 minutes.
- Test copies: their own folder outside the live install, port 8091, unelevated unless a step needs another PC;
  never touch the user's config or `lib\`.
- Every PR: CHANGELOG `[Unreleased]` entry, README updates, `Closes #<story>`, the story's labels and milestone
  v0.7.0, the budget table in the description, and the owner's UAT before merge.
- Commit and PR messages: BOM-less UTF-8 files under `.git\`, `git commit -F` / `gh pr create --body-file`, ending
  with the attribution lines.

## Review Focus

Failure modes the spec implies that no test in the test plan exercises yet. Each has a test added to its task below;
the task that adds it also adds the id to the test plan's section 6 and 7 tables, so the traceability check passes.

1. **The data drive comes back after a fallback.** Expected: SRRVRR stays on the fallback until restart, the drives
   card shows the drive present again, and the fallback flag isn't raised a second time. (Task 10, `T48-71`.)
2. **The data drive fills up** (an `IOException` for disk full, not access denied). Expected: the same fallback and
   flag as a read-only folder, and the write that failed is retried on the fallback. (Task 10, `T48-72`.)
3. **A daylight-saving change.** Expected: one event log file per local date, a 23- or 25-hour day writes to the right
   file, and ids stay strictly increasing. (Task 19, `T50-57`.)
4. **Many browsers polling at once** (10 clients every 0.5 s). Expected: `/stats` p95 stays within 30 ms and the tick
   stays within budget. (Task 23, `T50-58`.)
5. **Maintenance ended while SRRVRR was stopped.** Expected: it starts with Maintenance off, logs "Maintenance ended"
   once with the original end time, and banners resume. (Task 20, `T50-59`.)

---

## How to run things

- Checks, the way CI runs them: `powershell -NoProfile -ExecutionPolicy Bypass -File tools\Invoke-Checks.ps1`
  (default levels Static, Unit, Integration). Add `-Coverage` for the coverage report, `-Smoke` for the test-build
  tests. One test file: add `-Path tests\<Name>.Tests.ps1`.
- Pester 5 and PSScriptAnalyzer must be installed for the current user before Task 1 (owner's checklist item 1).
  Until then only `tools\Test-Parse.ps1` and `tools\Test-Ascii.ps1` run locally, and CI runs the rest.
- A test build: `tools\New-TestBuild.ps1 -Ref <branch> -Destination <test folder> -Port 8091`, then
  `"<test folder>\Start SRRVRR.bat"`; stop it with that folder's `Stop SRRVRR.bat`.
- Commit after each task's tests pass; push and open the story's PR when its last task is done; stack each story's
  branch on the one before (`feature/47-foundation` <- `feature/48-running-safely` <- `feature/49-history` <-
  `feature/50-events`; `feature/51-readme` on `feature/48-running-safely`).

Each task below follows the same cycle, so the steps are written once here and each task lists only what's
specific to it:

- [ ] **Write the failing tests** named in the task (assertions as in the test plan, section 6, for each id).
- [ ] **Run them and see them fail:** `tools\Invoke-Checks.ps1 -Path <test files>`; expected: the new tests fail
  for the missing function or behavior, nothing else fails.
- [ ] **Implement** the interfaces listed, in the files listed.
- [ ] **Run them and see them pass,** then the whole suite: `tools\Invoke-Checks.ps1`; expected: all pass,
  `Test-Ascii` and `Test-Parse` clean.
- [ ] **Commit** the task's files with a message naming the task.

---

## Story #47: Foundation, no change in behavior (branch `feature/47-foundation`)

The one intended behavior change in this story is the `Host` allowlist and the static path table (spec section 8):
a request with a foreign `Host` gets 421, and an unknown path gets 404 instead of the page.

### Task 1: Repo scaffolding and the check tools

**Files:**
- Create: `.gitattributes` (export-ignore for `tests/`, `.github/`, `docs/`, `tools/`, `.gitattributes`,
  `.gitignore`; `*.bat text eol=crlf`)
- Modify: `.gitignore` (add `state/`, `logs/`, `out/`)
- Create: `tools\Test-Ascii.ps1`, `tools\Test-Parse.ps1`, `tools\Test-NoPrivateInfo.ps1`, `tools\Test-PathLength.ps1`,
  `tools\PSScriptAnalyzerSettings.psd1`, `tools\Invoke-Checks.ps1`, `tests\PesterConfiguration.psd1`
- Create: `tests\TestHelpers.psm1` (the generic functions: `New-FakeClock`, `New-TestDataPath`,
  `Remove-TestDataPath`, `New-ReadOnlyFolder`, `Get-FreePort`, `Invoke-TestRequest`, `Read-JsonLines`,
  `ConvertTo-JsonShape`, `Wait-Until`, `Get-ScriptAst`, `Get-HereString`, `Get-AddTypeSource`,
  `Invoke-InChildPowerShell`, `Assert-NoCanary`)
- Test: `tests\Static.Tests.ps1`, `tests\Repo.Tests.ps1`

**Interfaces:**
- Produces: `tools\Invoke-Checks.ps1 [-Level Static,Unit,Integration] [-Smoke] [-Elevated] [-Coverage] [-CI]
  [-Path <files>]`, exit 0 all passed, 1 failures, 2 pinned tool missing. Pinned versions as two variables at the top
  (`$PesterVersion`, `$AnalyzerVersion`: the newest stable 5.x and 1.x on the day this is built).
- Produces: `TestHelpers` functions with the signatures in test plan section 4.1.

**Tests:** T47-01 to T47-06, T47-24, T47-32 to T47-34. `Static.Tests.ps1` starts with the rules from test plan
section 3.2 marked (S); rules for files that don't exist yet are skipped with `-Skip:(-not (Test-Path ...))` and
switch on as later tasks add the files.

### Task 2: CI workflow

**Files:**
- Create: `.github\workflows\checks.yml`
- Test: `tests\Repo.Tests.ps1` (T47-25)

**Interfaces:**
- Consumes: `tools\Invoke-Checks.ps1` (Task 1).
- Produces: jobs `static`, `analyze`, `test`, `measure` as in test plan section 5: `shell: powershell` on every
  step, a pinned `windows-2022` image, actions pinned to full commit SHAs, `permissions: contents: read`, one run per
  branch. Advisory: no branch protection change (the owner decides after three green PRs in a row).

**Tests:** T47-25.

### Task 3: Counters module and the fast tick

**Files:**
- Create: `modules\Counters.psm1`, `modules\Platform.psm1` (only `Read-CounterCategory` for now)
- Create: `tests\fakes\FakeCounterReader.psm1`, `tests\fakes\FakeProcessSource.psm1`, `tests\fixtures\counters\*.json`,
  `tests\fixtures\processes\*.json`
- Modify: `SRRVRR.ps1` (fast sampler body, about lines 507-640, becomes one call)
- Test: `tests\Counters.Tests.ps1`

**Interfaces:**
- Produces: `Invoke-FastTick -State <hashtable> -Reader <scriptblock> -Processes <scriptblock> -Tracer <object>
  -Stopwatch <Diagnostics.Stopwatch> -Previous <hashtable>` returns the new `Previous` snapshot and sets
  `$State.tickMs` (milliseconds, one decimal) and today's `$State` fields unchanged.
- Produces: `Read-CounterCategory -Name <string>` (Platform) returns `ReadCategory()`'s shape.
- Produces: `Get-TracerLogEntry -Current <hashtable> -LastLogged <hashtable>` returns `$null` or
  `@{ Level; Message }` (used in Task 9).

**Tests:** T47-11 to T47-16. The runspace imports `modules\Counters.psm1` by full path through
`InitialSessionState.ImportPSModule` (test plan rule 9).

### Task 4: Settings module (existing settings only)

**Files:**
- Create: `modules\Settings.psm1`
- Create: `tests\fixtures\config\*.psd1` (the existing settings' boundaries)
- Modify: `SRRVRR.ps1` (settings section, about lines 137-254)
- Test: `tests\Settings.Tests.ps1`

**Interfaces:**
- Produces: `Get-SrrDefaultSettings` returns a hashtable of every setting and default.
- Produces: `Test-SrrSettings -Settings <hashtable> -Retired <string[]>` returns `@{ Settings; Notes }` or throws
  (a plain `throw` for now; Task 8 switches it to `SrrSettingsException`).
- Produces: `Import-SrrSettings -Folder <string> -PortOverride <int>` reads `SRRVRR.config.psd1` (legacy
  `SystemMonitor.config.psd1`) and returns `Test-SrrSettings`' result.
- Produces: `Test-PrivateAddress -Address`, `Test-SingleAddress -Address` (moved from the firewall checks).

**Tests:** T47-29, T47-30.

### Task 5: Web module: router, host allowlist, static files

**Files:**
- Create: `modules\Web.psm1`
- Create: `tests\fixtures\stats\v0.6.0-shape.json` (captured from v0.6.0's `/stats` with `ConvertTo-JsonShape`)
- Modify: `SRRVRR.ps1` (listener loop, about lines 1466-1491; it builds the request hashtable, calls
  `Invoke-SrrRoute`, writes the result)
- Modify: `tests\TestHelpers.psm1` (add `Start-TestServer`, `Stop-TestServer`)
- Test: `tests\Web.Tests.ps1`

**Interfaces:**
- Produces: `Invoke-SrrRoute -Method <string> -Path <string> -Query <hashtable> -Headers <hashtable> -Body <string>
  -RemoteAddress <string> -LocalPort <int> -Context <hashtable>` returns `@{ Status; ContentType; Body; Headers }`
  (`Body` is `[byte[]]` for images, `[string]` otherwise).
- Produces: `Get-StaticRoute -UrlPath <string>` returns `@{ File; ContentType }` or `$null`.
- Produces: `Test-HostAllowed -HostHeader <string> -Port <int> -Identity <hashtable>` returns `[bool]`;
  `Get-HostIdentity` (Platform) returns `@{ Names; Addresses }`, rebuilt once a minute by the slow sampler.
- Produces: `New-StatsSnapshot -State <hashtable> -Now <DateTimeOffset>` returns the `/stats` hashtable.
- Rules: GET only (POST only on `/maintenance`, added in Task 20) else 405; foreign `Host` 421; unknown path 404; no
  `Access-Control-*` headers; `X-Content-Type-Options: nosniff`; a missing `web\` file 500 with an error-log line
  (the log call is a no-op until Task 9). Trailing-dot names refused; IPv6 zone ids stripped.

**Tests:** T47-17, T47-20 to T47-23, T47-36 to T47-39.

### Task 6: The page moves to `web\`

**Files:**
- Create: `web\index.html`, `web\app.js`, `web\style.css`, `web\img\*` (from the here-string and its data URIs)
- Modify: `SRRVRR.ps1` (remove the `$html` here-string, about lines 975-1390)
- Create: `tests\js\app.test.js`
- Test: `tests\Page.Tests.ps1`

**Interfaces:**
- Produces: `web\app.js` pure functions with no DOM access, exported for Node when `module` exists: `bits`, `niceMax`,
  `since`, `size`, `speed`, `plexRes`, `plexDevice` (later tasks add `shouldBanner`, `nextSince`,
  `rangeFromStorage`, `fillFromHistory`, `visibleSlice`, `toSegments`).
- Rule: the rendered page matches v0.6.0's (T47-19 compares the DOM text and element ids).

**Tests:** T47-19, T47-31, T47-40.

### Task 7: Test builds, measuring and the #47 UAT

**Files:**
- Create: `tools\SRRVRR.Tools.psm1`, `tools\budgets.psd1`, `tools\Measure-SRRVRR.ps1`, `tools\New-TestBuild.ps1`,
  `tools\Invoke-UatChecks.ps1`, `tests\fakes\FakeStatsServer.ps1`, `docs\uat\_template.md`,
  `docs\uat\47-foundation.md`
- Modify: `tests\TestHelpers.psm1` (add `New-TestBuild`, `Start-TestBuild`, `Stop-TestBuild`)
- Modify: `README.md` (how to run the checks; the page lives in `web\`), `CHANGELOG.md`
- Test: `tests\Tools.Tests.ps1`, `tests\Smoke.Tests.ps1` (tag `Smoke`)

**Interfaces:**
- Produces: `tools\New-TestBuild.ps1 -Ref -Destination [-Port 8091] [-DataPath] [-LiveFolder] [-Force]` writes
  `TESTBUILD.txt` (ref, commit, time) and a test config; refuses as in test plan section 4.4.
- Produces: `tools\Measure-SRRVRR.ps1 -BaseUrl -Folder [-Seconds 60] [-SoakMinutes 0] [-Budgets] [-OutFile]
  [-Informational]`; prints the markdown budget table; exit 1 over budget.
- Produces: `tools\budgets.psd1` with the spec's numbers and the v0.6.0 baseline; `TickMsBaseline` filled from this
  PR's measurement.

**Tests:** T47-07 to T47-10, T47-18, T47-26 to T47-28, T47-35.

- [ ] **PR for #47:** push `feature/47-foundation`, open the PR (`Closes #47`, labels `enhancement`, `ui`), paste the
  `Measure-SRRVRR.ps1` table, stage the test build and stop for the owner's UAT (`docs\uat\47-foundation.md`).

---

## Story #48: Running safely (branch `feature/48-running-safely`, on #47)

### Task 8: Exit codes and the new settings

**Files:**
- Modify: `modules\Settings.psm1` (new settings; the C# exception source as a here-string, compiled once on import
  and guarded against recompiling)
- Modify: `SRRVRR.ps1` (the `trap` and one `Exit-SRRVRR` function), `SRRVRR.config.example.psd1`
- Test: `tests\Settings.Tests.ps1`, `tests\ExitCodes.Tests.ps1`

**Interfaces:**
- Produces: C# classes `SrrSettingsException` and `SrrRefusalException` (both derive from `System.Exception`).
- Produces: `Get-SrrExitCode -ErrorRecord <ErrorRecord>` returns 2, 3 or 1, looking through `InnerException`.
- Produces: `Exit-SRRVRR -Code <int> -Reason <string>` (in `SRRVRR.ps1` only) writes the last log line and exits.
- Produces: `Format-StopLine -Reason <string> -Code <int>` returns `stopped: <reason> (exit <code>)`.
- Settings: `DataPath` (full local path with a drive letter; existence not checked), `LogRetentionDays` 7..366,
  `MaintenanceHours` 0.25..`MaintenanceMaxHours`, `MaintenanceMaxHours` 1..24.

**Tests:** T48-22 to T48-28.

### Task 9: Crash and error log, worker watcher, tracer errors

**Files:**
- Create: `modules\Logging.psm1`
- Modify: `SRRVRR.ps1` (the `ProcessNetTrace` C# keeps last error text, type, count and an alive flag; the main
  loop checks the workers once a second; `Set-Step` writes each step to the log)
- Test: `tests\Logging.Tests.ps1`, `tests\Workers.Tests.ps1`

**Interfaces:**
- Produces: `Format-LogLine -Time <DateTimeOffset> -Level <INFO|WARN|ERROR|FLAG> -Source <string> -Message <string>`
  returns `yyyy-MM-ddTHH:mm:ss.fff+hh:mm LEVEL source: message` with newlines escaped.
- Produces: `New-ErrorThrottle -Clock <scriptblock> [-WindowSeconds 60]` with `.ShouldWrite(key)` returning
  `@{ Write; Repeats }`.
- Produces: `New-DailyLog -Folder <string> -Prefix <string> -Extension <string> -Clock <scriptblock>
  [-CapBytes 20MB]` with `.Write(line, isFlagOrFinal)`; one writer per file, `FileShare.Read`.
- Produces: `Format-SrrException -ErrorRecord` returns type, message, script line and stack as one string.
- Produces: `Test-WorkerHealth -Workers <object[]>` returns `@{ Healthy; Reason; Errors }`.

**Tests:** T48-21, T48-29 to T48-32, T48-55, T48-56, T48-59 to T48-64.

### Task 10: The data folder

**Files:**
- Modify: `modules\Settings.psm1`, `modules\Platform.psm1` (`Get-ShareList`, `Test-Elevated`, `Set-DataFolderAcl`,
  `Get-VolumeInfo`)
- Create: `tests\fakes\FakeShareList.psm1`
- Modify: `tests\TestHelpers.psm1` (add `New-FakeShareList`, `New-TestJunction`, `Lock-TestDataPath`)
- Test: `tests\DataPath.Tests.ps1`

**Interfaces:**
- Produces: `Test-PathInShare -Path <string> -Shares <object[]>` returns the matching share or `$null` (equal, above or
  below; junctions resolved; whole segments; case-insensitive; type bit 0x80000000 ignored).
- Produces: `Resolve-DataPath -Setting <string> -OwnFolder <string> -Shares <object[]> -IsElevated <bool>
  -TestWritable <scriptblock>` returns `@{ Path; IsFallback; Reason }` or throws `SrrRefusalException`. Order: the lock
  first, then the share check, then writability (spec section 9).
- Produces: `Lock-DataPath -Path` returns an open `FileStream` (`FileShare.None`) or throws `SrrRefusalException`.
- Produces: `Get-DataFolderAclPlan -Acl <FileSystemSecurity>` returns the rules to remove and whether inheritance must
  be turned off.
- Produces: `Write-DataFile -Path <string> -Content <string|byte[]>`: the one write path; a write failure switches to
  the fallback once and raises a flag event through `Add-SrrQueueItem` (a no-op stub until Task 17).

**Tests:** T48-01 to T48-20, plus:
- `T48-71` (Review Focus 1): after a fallback, `Get-VolumeInfo` reports the data drive again; expect `IsFallback` still
  true, the drive listed as present, and exactly one fallback flag event.
- `T48-72` (Review Focus 2): `-TestWritable` passes, then the write throws `IOException` with HResult `0x80070070`
  (disk full); expect the fallback, one flag event, and the content written to the fallback folder.

### Task 11: Graceful stop

**Files:**
- Create: `modules\Control.psm1`
- Modify: `modules\Platform.psm1` (`New-StopEvent`, `Open-StopEvent`, `Get-SRRVRRProcessList`)
- Modify: `SRRVRR.ps1` (the `-Stop` block, about lines 20-53; `Test-StopSignal` in the loop and in every `Set-Step`;
  Ctrl+C read as a key with `[Console]::TreatControlCAsInput` when a console is attached), `Stop SRRVRR.bat`
- Modify: `tests\TestHelpers.psm1` (add `New-SquattedStopEvent`)
- Create: `tests\fakes\FakeLauncher.ps1`
- Test: `tests\Stop.Tests.ps1`

**Interfaces:**
- Produces: `ConvertTo-StopPath -Folder <string>` (mapped drive to network path, long names, no trailing `\`, upper
  case) and `Get-StopEventName -Folder -Elevated <bool>` returns `Global\SRRVRR-stop-<16 hex>` or
  `Local\SRRVRR-stop-<16 hex>`.
- Produces: `New-StopEventSecurity -Elevated <bool>` returns an `EventWaitHandleSecurity`;
  `Test-StopEventTrusted -Owner <SecurityIdentifier> -Rules <object[]> -Elevated <bool>` returns `[bool]`.
- Produces: `Invoke-StopCommand -Folder -Openers <hashtable> -Clock -WaitSeconds 10` returns
  `@{ Action; Signalled; Forced; ExitCode }`; writes `state\stop-requested` first.
- Produces: `Select-SRRVRRProcess -Folder <string> -Processes <object[]> -SelfId <int>` returns matching processes.
- Produces: `Invoke-GracefulStop -Savers <scriptblock[]> -Reason <string>` saves, logs and returns 0.
- Produces: `Test-StopSignal` (wraps `WaitOne(0)`; mocked in tests).

- [ ] **Step 1 (first, before the rest of this task): prove Ctrl+C.** Write T48-57 and make it pass with
  `TreatControlCAsInput`. If it can't pass on Windows PowerShell 5.1, stop and report to the owner before going on
  (spec section 9 names this as the first thing #48 proves).

**Tests:** T48-33 to T48-43, T48-52 to T48-54, T48-57, T48-58, T48-67.

### Task 12: Test copies and firewall rules per copy

**Files:**
- Modify: `modules\Control.psm1`, `modules\Platform.psm1` (`Sync-FirewallRule`)
- Modify: `SRRVRR.ps1` (firewall reconcile, about lines 1400-1421; the listener prefix choice)
- Test: `tests\Firewall.Tests.ps1`, `tests\TestBuild.Tests.ps1`

**Interfaces:**
- Produces: `Get-SrrCopyKind -Folder <string>` returns `live` or `test` (test when `TESTBUILD.txt` is present).
- Produces: `Get-FirewallRulePlan -Copy <live|test> -Scope <string> -Addresses <string[]> -Port <int>` returns
  `@{ Add; Remove }` with names "SRRVRR" / "SRRVRR (blocked)" or "SRRVRR (test)" / "SRRVRR (test, blocked)", groups
  "SRRVRR" or "SRRVRR (test)", and the legacy "System Monitor" rules removed only for `live`.
- Produces: `Get-ListenerPrefix -Elevated <bool> -Port <int>` returns `http://+:<port>/` or
  `http://localhost:<port>/`.

**Tests:** T48-44 to T48-51.

### Task 13: The data drive on the drives card

**Files:**
- Modify: `modules\Control.psm1`, `SRRVRR.ps1` (slow sampler's drive list, about line 815)
- Test: `tests\Drives.Tests.ps1`

**Interfaces:**
- Produces: `Select-DrivesToShow -Volumes <object[]> -DataPath <string> -MinBytes 1GB` returns the drive list: fixed
  drives as today, plus the data drive (found with `Win32_Volume`, never skipped for size, shown as missing when
  absent; the fallback drive while on fallback).

**Tests:** T48-65, T48-66.

### Task 14: README, UAT and measuring for #48

**Files:**
- Modify: `README.md` (`-Stop` and test-copy text; closing the console window is a hard stop), `CHANGELOG.md`
- Create: `docs\uat\48-running-safely.md`
- Test: `tests\Docs.Tests.ps1` (T48-68)

**Tests:** T48-68 to T48-70.

- [ ] **PR for #48:** push `feature/48-running-safely`, open the PR (`Closes #48`, labels `enhancement`, `startup`,
  base `feature/47-foundation`), paste the budget table, stage the test build and stop for the owner's UAT.

---

## Story #49: History (branch `feature/49-history`, on #48)

### Task 15: History module

**Files:**
- Create: `modules\History.psm1`, `tests\fixtures\history\*.json`
- Test: `tests\History.Tests.ps1`

**Interfaces:**
- Produces: `New-HistoryStore -Clock <scriptblock> [-Slots 900] [-StepMs 1000]` with `.Register(name)`,
  `.Append(name, value)` (non-numbers stored as `null`), `.Copy()` returning `@{ NewestMs; StepMs; Lines }`; one lock
  held only for the append and the copy.
- Produces: `ConvertTo-HistoryJson -Copy <hashtable>` (a `StringBuilder`, no `ConvertTo-Json`).
- Produces: `Save-History -Store -StatePath <string>` (tmp then `[IO.File]::Replace`, or a move with no file yet; uses
  `Write-DataFile`).
- Produces: `Import-History -StatePath -Store -Now <DateTimeOffset> [-MaxBytes 2MB] [-MaxAge 15min]` returns
  `@{ Loaded; Reason }`; renames to `.bad` for damaged, oversized or unknown-version files; ignores (doesn't rename)
  stale or future files.
- Produces: `Test-HistorySaveDue -LastSave <DateTimeOffset> -Now <DateTimeOffset> [-Interval 5min]`.

**Tests:** T49-01 to T49-17.

### Task 16: History wired in, `/history` and the 15-minute button

**Files:**
- Modify: `modules\Counters.psm1` (`Invoke-FastTick` appends to the store), `SRRVRR.ps1` (the slow tick saves; the
  stop path saves; the store is loaded at start), `modules\Web.psm1` (`GET /history`)
- Modify: `web\app.js`, `web\index.html`, `web\style.css` (60 s / 15 min buttons, remembered per browser)
- Modify: `README.md`, `CHANGELOG.md`; Create: `docs\uat\49-history.md`
- Test: `tests\History.Tests.ps1`, `tests\js\history.test.js`

**Interfaces:**
- Consumes: `New-HistoryStore`, `ConvertTo-HistoryJson`, `Save-History`, `Import-History` (Task 15);
  `Invoke-GracefulStop -Savers` (Task 11).
- Produces: `web\app.js`: `fillFromHistory(json)`, `rangeFromStorage(storage)` (60 or 900; a throwing storage
  returns 60), `visibleSlice(buffer, range)`, `toSegments(values)` (nulls split segments).

**Tests:** T49-18 to T49-30.

- [ ] **PR for #49:** push `feature/49-history`, open the PR (`Closes #49`, labels `enhancement`, `ui`, base
  `feature/48-running-safely`), paste the budget table, stage the test build and stop for the owner's UAT.

---

## Story #50: Events, logs, Maintenance and the Flagged list (branch `feature/50-events`, on #49)

### Task 17: Event core: ids, queue, drain

**Files:**
- Create: `modules\Events.psm1`
- Modify: `modules\Settings.psm1` (`Write-DataFile`'s flag goes through the real queue now)
- Test: `tests\Events.Tests.ps1`

**Interfaces:**
- Produces: `New-EventId -NowMs <long> -LastId <long>` returns `max(NowMs, LastId + 1)`.
- Produces: `New-SrrEvent -Type <string> -Severity <info|warn|flag> -Key <string> -Data <hashtable>`.
- Produces: `New-SrrQueue` (a `ConcurrentQueue[object]`) and `Add-SrrQueueItem -Queue -Item` (events and errors).
- Produces: `New-EventStore -Clock [-Size 200] [-SuppressFor 10min]` with `.Published` (an array replaced, never
  changed in place) and `.LastId`.
- Produces: `Invoke-QueueDrain -Queue -Store -Writers <hashtable> -Clock` assigns ids, suppresses repeats, writes
  logged events and errors, and publishes.

**Tests:** T50-01 to T50-06.

### Task 18: Event detection on the server

**Files:**
- Modify: `modules\Events.psm1` (change detection), `modules\Counters.psm1` / the slow tick (call it with old and new
  state)
- Create: `tests\fixtures\activity\*.json`
- Test: `tests\Detection.Tests.ps1`

**Interfaces:**
- Produces: `Get-StateEvents -Old <hashtable> -New <hashtable>` returns `New-SrrEvent` objects for every row of the
  spec's event table (section 4) except Maintenance, start and stop, which their owners raise.
- Rule: event data for banners may hold names; the logged copy holds counts only (`ConvertTo-LoggedEvent`).

**Tests:** T50-07 to T50-17, T50-19.

### Task 19: Event log, index and cleanup

**Files:**
- Modify: `modules\Events.psm1`, `SRRVRR.ps1` (load the index and run cleanup after the server is serving; cleanup
  daily in the slow sampler)
- Create: `tests\fixtures\events\*.jsonl`, `tests\fixtures\logs\names.txt`
- Test: `tests\EventLog.Tests.ps1`

**Interfaces:**
- Produces: `Initialize-EventIndex -LogDir -Days <int>` (bad lines skipped and counted) and
  `Get-IndexedEvents -Index -Days <int> [-Limit 1000]` (newest first).
- Produces: `Remove-OldLogs -LogDir -RetentionDays <int> -Now <DateTimeOffset> [-FloorDays 7]` returns the deleted
  names; `Test-CleanupDue -LastRun -Now`.
- Uses `New-DailyLog` (Task 9) for `events-YYYY-MM-DD.jsonl`, local date.

**Tests:** T50-18, T50-20 to T50-26, plus:
- `T50-57` (Review Focus 3): a fake clock across a spring-forward and a fall-back change; events written in the
  missing and the repeated hour land in that local date's file; ids strictly increasing throughout.

### Task 20: Maintenance

**Files:**
- Modify: `modules\Settings.psm1` (Maintenance state and its file), `modules\Web.psm1` (`POST /maintenance`, the guard,
  the rate limit)
- Create: `tests\fixtures\maintenance\*.json`
- Test: `tests\Maintenance.Tests.ps1`

**Interfaces:**
- Produces: `New-MaintenanceState -Clock -Hours <double> -MaxHours <double>` with `.SetOn(address)`,
  `.SetOff(address)`, `.IsOn()`, `.UntilMs`; `Save-Maintenance -State -StatePath`,
  `Import-Maintenance -StatePath -Now -MaxHours [-MaxBytes 4KB]` (damaged or oversized renamed `.bad`; end time held
  to `MaxHours` from now).
- Produces: `Test-MaintenanceRequest -Headers -Identity -Port` returns `@{ Ok; Status }` (header `X-SRRVRR: 1`,
  `Content-Type: application/json`, `Origin` required and in the identity list).
- Produces: `New-RateLimiter -Clock [-PerAddressSeconds 10] [-PerDay 60]` with `.Allow(address)`; counters reset at
  local midnight and on restart.

**Tests:** T50-27 to T50-38, T50-52, plus:
- `T50-59` (Review Focus 5): `maintenance.json` with `untilMs` in the past at start; expect Maintenance off, one
  "Maintenance ended" event carrying the original end time, and the next join event bannered.

### Task 21: `/stats?since=` and `/events`

**Files:**
- Modify: `modules\Web.psm1` (`New-StatsSnapshot` adds `maintenance`, `logRetentionDays`, `lastEventId`, `events`)
- Test: `tests\Web.Tests.ps1`

**Interfaces:**
- Consumes: `New-EventStore` (Task 17), `Get-IndexedEvents` (Task 19), `New-MaintenanceState` (Task 20).
- Produces: `Get-EventsSince -Store -Since <long> [-Limit 50]` returns `@{ Events; Truncated }` (the 50 just after the
  id; an id older than the store or in the future returns the newest 50).
- `/events?days=n`: whole number 1..`LogRetentionDays`, anything else (including missing) 400.

**Tests:** T50-39 to T50-44.

### Task 22: The page: server banners, Maintenance and the Flagged list

**Files:**
- Modify: `web\app.js` (remove `watchValheim` / `watchPlex`; banners from `events`), `web\index.html`, `web\style.css`
- Create: `tests\js\events.test.js`
- Test: `tests\Page.Tests.ps1` (T50-51)

**Interfaces:**
- Produces: `shouldBanner(event, maintenance)` and `nextSince(response, current)` in `web\app.js`; the Flagged list
  asks for `min(31, logRetentionDays)` days.

**Tests:** T50-45 to T50-51.

### Task 23: UAT, measuring and soak for #50

**Files:**
- Modify: `README.md`, `CHANGELOG.md`; Create: `docs\uat\50-events.md`
- Test: `tests\Smoke.Tests.ps1`

**Tests:** T50-53 to T50-56, plus:
- `T50-58` (Review Focus 4): `Measure-SRRVRR.ps1` with 10 concurrent clients polling `/stats` every 0.5 s for 60 s;
  expect `/stats` p95 within 30 ms and the tick median within budget.

- [ ] **PR for #50:** push `feature/50-events`, open the PR (`Closes #50`, labels `enhancement`, `ui`, `valheim`,
  `plex`, base `feature/49-history`), paste the budget table, stage the test build and stop for the owner's UAT. The
  60-minute soak (T50-56) runs during that UAT.

---

## Story #51: README: running SRRVRR at boot (branch `feature/51-readme`, on #48)

### Task 24: The boot section

**Files:**
- Modify: `README.md` (a "Running SRRVRR at boot" section: the entry script stays put, every runtime file is checked
  before it loads, the exit-code table, the stop signal and `stop-requested`, `DataPath`; the update steps become
  "replace the code folders"), `CHANGELOG.md`
- Create: `docs\uat\51-readme.md`
- Test: `tests\Docs.Tests.ps1`

**Tests:** T51-01 to T51-10.

- [ ] **PR for #51:** push `feature/51-readme`, open the PR (`Closes #51`, labels `enhancement`, `startup`, base
  `feature/48-running-safely`), stop for the owner's review. It may merge any time after #48.

---

## Release v0.7.0

- [ ] After #47 to #51 are merged (each on the owner's OK, in order, rebasing the later ones): a docs PR moves
  `[Unreleased]` to `0.7.0` and bumps the README version; merge it on the owner's OK; annotated tag `v0.7.0`;
  `gh release create v0.7.0` with that section as the notes, saying files carry the downloaded mark and load because
  SRRVRR is always started with `-ExecutionPolicy Bypass`.
- [ ] The boot launcher's release that carries v0.7.0 is tracked outside this repo; it must be installed before
  v0.7.0 runs at boot (spec section 7).

## Execution notes

- **Parallel work:** within a story the tasks build on each other's interfaces, so they run in order. Two pairs are
  independent and can run side by side if the owner wants agents: Task 2 (CI) with Task 3 (Counters), and Task 6
  (the page) with Task 5 (the router) once Task 5's `Get-StaticRoute` signature is fixed. Each agent writes to its
  own files only and reports to a file as it goes.
- **Size:** 24 tasks; about 206 tests from the test plan plus 5 from Review Focus.
