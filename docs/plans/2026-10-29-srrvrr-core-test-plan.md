# SRRVRR core (v0.7.0): test plan

Status: draft for the owner's review. Covers stories #47 to #51 (milestone v0.7.0) against the design spec
`docs/specs/2026-10-28-srrvrr-core-design.md`.

## Contents
- [1. Scope and coverage goals](#1-scope-and-coverage-goals)
- [2. Test levels](#2-test-levels)
- [3. Design-for-testability rules for the build](#3-design-for-testability-rules-for-the-build)
- [4. Reusable test assets in the repo](#4-reusable-test-assets-in-the-repo)
- [5. CI](#5-ci)
- [6. Test cases per story](#6-test-cases-per-story)
- [7. Traceability](#7-traceability)
- [8. Test data, environments and running the tests](#8-test-data-environments-and-running-the-tests)
- [9. Risks and open questions](#9-risks-and-open-questions)

## 1. Scope and coverage goals

**In scope:** everything the spec adds or changes in v0.7.0: the modules, the page moved to `web\` with its fixed path table, the
`Host` and `Origin` checks, history, events, the two logs, Maintenance, the Flagged list, `DataPath` with its fallback, share check, lock and permissions,
the graceful stop, the exit codes, test builds and their firewall rules, the drives card change, the new settings, the
budgets, CI, and the README (#51). Existing behavior that #47 moves without changing (the `/stats` fields, the
page, the counter math, the settings validation that already exists) is covered by parity and regression tests.

**Out of scope:** v0.8.0 and later (spec "Not in this release"); the boot launcher itself (a separate project:
this plan only tests the contract SRRVRR offers it: exit codes, the stop signal, the runtime file list); the
temperature library and its installer, beyond "SRRVRR still starts with and without it".

### What "100%" means here

There are three numbers, each measured, and one explicit gap list. None of them is "100% of everything".

| Measure | Target | How it's measured | Gate |
|---|---|---|---|
| **Requirement coverage** | 100% of spec requirements (section 7) have at least one test id; every one that can be automated has an automated test | `tests\Traceability.Tests.ps1` reads the table in section 7 of this plan and checks that every test id it names exists in a `tests\*.Tests.ps1` file (as an `It` name prefix) or in a `docs\uat\*.md` checklist | Required from #47 |
| **Code coverage, modules** | 100% of commands in `modules\*.psm1` except `Platform.psm1` (Pester 5 "commands" coverage, which is what Pester measures; the JaCoCo report's line figure is reported next to it, also 100%) | Pester 5 `CodeCoverage` over `modules\*.psm1`, run in-process | Reported from #47; enforced at 100% once CI becomes required (after three green PRs in a row, section 5) |
| **Code coverage, `Platform.psm1`** | No percentage; every function in it is listed in the gap table below with its covering test | Same run (reported) | Review |
| **Code coverage, tool module** | 90% of commands in `tools\SRRVRR.Tools.psm1` | Same run | Advisory |
| **Residual script size** | `SRRVRR.ps1` keeps no decision logic outside the regions listed in the gap table below; anything with a branch that isn't OS plumbing moves to a module | Code review against the gap table; `tests\Static.Tests.ps1` counts functions defined in `SRRVRR.ps1` and fails if a new one appears that isn't on its allow list | Required from #48 |

Pester can't measure code that runs inside another runspace or another process (its coverage hooks are per
runspace). So **all logic is exercised by calling module functions directly in the test's own runspace,** and
the runspaces in `SRRVRR.ps1` are kept as thin loops that call those functions (section 3). That's what makes
100% of the modules reachable, and it's why `SRRVRR.ps1` itself has no percentage target.

**Pester has no "ignore this line" pragma.** 100% on the modules therefore means: no dead branches. A defensive
`catch` that can't be reached with a fake or a mock is removed, or moved to `modules\Platform.psm1` (below).

### The explicit gap: what can't be unit-covered in-process, and what covers it instead

`modules\Platform.psm1` holds the thin wrappers around the operating system (each a few lines with no decisions
of their own). It's excluded from the 100% target and listed here instead, with its covering tests.

| Code | Why not unit-covered | Covered by | Where it runs |
|---|---|---|---|
| Runspace bootstrapping in `SRRVRR.ps1` (creating runspaces, importing modules into them, the loops) | Another runspace; Pester coverage can't see it | Integration test that starts the samplers' loop functions in a real runspace with fakes (T47-14); smoke tests on a test build (T48-51 to T48-58) | Local and CI |
| The startup spinner, `Write-Status`, `Set-Step`, console cursor | Console UI | Static check of the `Steps` count (T47-07); smoke log check that every step is logged (T48-21) | Local and CI |
| The C# ETW network tracer (`ProcessNetTrace`) and the two C# exception classes | Kernel session needs administrator; C# isn't measured by Pester | Every `Add-Type` block compiled by the parse step (T47-32); unelevated child-process test: `Start()` returns false with "needs administrator" (T48-29). Elevated, CI only: `Start()` succeeds, the alive flag is set, `Drain()` sees bytes (T48-30) | Local (unelevated part), CI (elevated part) |
| Firewall cmdlets (`Get/New/Remove-NetFirewallRule`) | Change machine state; never run on the dev PC | Pure rule-plan function unit-covered (T48-43 to T48-46); the wrapper tested CI-only, elevated, on the throwaway runner (T48-47, T48-48) | CI only |
| Named stop event in the machine-wide namespace, with its access rules; the data folder permissions fix | Need administrator | Access rules built and checked by pure functions, unit-covered (T48-18, T48-33, T48-35); CI-only tests that create them and read them back (T48-19, T48-34) | CI only |
| Network share list (`Win32_Share`) | Real shares need administrator to create | Pure share check with a fake share list, unit-covered (T48-01 to T48-08); CI-only test with real shares above and below the data folder (T48-09) | Local (fake), CI (real) |
| `HttpListener` binding to all addresses (`http://+:port/`) | Needs administrator or a URL reservation | The router and the prefix choice are unit-covered (T48-46); the listener is integration-tested on `localhost`; the all-addresses bind is smoke-tested on CI (elevated) and in UAT | CI and UAT |
| Elevation checks, `-Stop`'s administrator prompt | Needs UAC interaction | Decision function unit-covered (T48-38); the prompt itself in UAT (`docs\uat\48-running-safely.md`) | UAT |
| Drive health, removable drives, mount points (`Get-Disk`, `Get-PhysicalDisk`, `Win32_Volume`) | Real hardware | Pure drive selection unit-covered (T48-65, T48-66); UAT with a spare removable drive | UAT |
| The page's JavaScript | Not PowerShell | `node --test` unit tests of the pure functions in `web\app.js` (section 2), CI only; the rest in UAT | CI and UAT |
| Hard process death (killed, out of memory, console window closed) | Can't write a last line by design | Test that a killed copy leaves no "stopped:" line and a crash-looking exit code (T48-58); the launcher's own records and the `stop-requested` marker | Local and CI |
| The boot launcher's restart policy | Another project | A reference fake launcher in `tests\fakes\` that implements the documented contract, driven by stub scripts (T48-67); the real launcher's own tests | Local and CI |

**Each release reports the gap as numbers,** in the PR description of #50 and in the release notes: modules
command coverage (target 100%), tool module coverage, number of requirements with an automated test, number
covered only by UAT (target: the ones marked "UAT only" in section 7, no more).

## 2. Test levels

Each test file declares its level with a Pester tag. `tools\Invoke-Checks.ps1` picks levels by tag.

| Level | Tag | What it tests | Tools and fakes | Where | Time budget |
|---|---|---|---|---|---|
| Static | `Static` | Parse, ASCII, structure rules (section 3) checked on the source with the PowerShell parser's AST | `tools\Test-Ascii.ps1`, `tools\Test-Parse.ps1`, `tests\Static.Tests.ps1` | Local, CI | 10 s |
| Unit | `Unit` | Pure functions in `modules\*.psm1` and `tools\SRRVRR.Tools.psm1` | Pester 5 `Mock`, the fake clock, fake counter reader, fake share list, fixtures, `TestDrive:` | Local, CI | 30 s |
| JS unit | `Js` (run by `node --test`, not Pester) | Pure functions in `web\app.js`: banner choice, `since` tracking, Maintenance gating, graph range memory | `tests\js\*.test.js`, no npm packages | CI (skipped locally when `node` isn't on the path) | 5 s |
| Integration | `Integration` | Modules working with real files and a real `HttpListener` on `http://localhost:<free port>/` with a temp `DataPath`; a sampler loop in a real runspace with fakes; the C# tracer compiled in a child process | `tests\TestHelpers.psm1` (`Start-TestServer`, `New-TestDataPath`, `Get-FreePort`, HTTP helpers) | Local, CI | 60 s |
| Elevated integration | `Elevated` | Firewall rules per copy, the machine-wide stop event and its access rules, a real network share, the ETW session | Same helpers; runs only when `$env:GITHUB_ACTIONS -eq 'true'` and the process is elevated | CI only (the runner is a throwaway machine; never the dev PC or the server) | 30 s |
| Smoke (end to end) | `Smoke` | A real test build started from its own folder, unelevated, as a child `powershell.exe`: starts, serves `/`, `/stats`, `/history`, `/events`; stops gracefully on `-Stop`; exit codes for settings errors, refusals and crashes; two copies don't touch each other | `tools\New-TestBuild.ps1`, `Start-TestBuild` / `Stop-TestBuild` in `TestHelpers` | Local (opt-in `-Smoke`), CI | 3 min |
| Performance | `Perf` (not Pester) | The spec's budgets | `tools\Measure-SRRVRR.ps1` against a test build on port 8091 (local) or on the runner (CI, informational only) | Local before every PR; CI informational | 2 min quick, 60 min soak |
| Security / negative | `Security` (also carries its level tag) | Request-forgery guard, stop-signal access rules, share check, cleanup deleting only matching old files, size caps, path traversal on `web\`, names never in logs | Mixed: mostly Unit and Integration | Local, CI | inside the levels above |
| Owner UAT | (markdown) | What only the owner can judge or do: two PCs, real drives, the look of the page, the boot launcher | `docs\uat\<story>.md` checklists plus `tools\Invoke-UatChecks.ps1` (read-only) | The owner's test build on port 8091 | about 15 min per PR |

**Unit** tests never touch the network, the registry, performance counters, the real clock or files outside
`TestDrive:`. Anything that would is passed in (section 3) or mocked with `Mock -ModuleName`.

**Integration** tests use a fresh temp `DataPath` per `Describe` (under `$env:TEMP\srrvrr-tests\<guid>`, removed
in `AfterAll`), a random free port (never 8091, so a running test build isn't disturbed), and real files. They wait
with `Wait-Until` (poll with a timeout), never a bare `Start-Sleep`.

**Smoke** tests build the copy under test with `tools\New-TestBuild.ps1 -Ref HEAD` into a temp folder, give it a
config with a free port, start it unelevated with `powershell.exe -NoProfile -ExecutionPolicy Bypass -File`, and
read its exit code with `-PassThru`. They never start anything from the live install, never use the live
install's stop event name, and refuse to run if the test build's folder is the live install (`New-TestBuild`
checks a `-LiveFolder` the owner passes, or `$env:SRRVRR_LIVE_FOLDER`; nothing in the repo names that folder).

**Performance** runs `tools\Measure-SRRVRR.ps1 -BaseUrl http://localhost:8091 -Folder <test build folder>` and
compares against `tools\budgets.psd1` (the spec's table as data). It only reads: HTTP GETs, performance counters,
process information and file sizes. On the CI runner the numbers are recorded but never fail a build (shared
hardware); on the owner's machine they go in the PR description next to the baseline.

**Security / negative** tests are listed with an `X` in the level column in section 6; each has its own id. The
main groups:
- `Host` allowlist (421, including a DNS-rebinding request) and the request-forgery guard on
  `POST /maintenance`: header, content type, `Origin` (required: no `Referer` fallback), scheme, port, `null`
  origin, preflight never answered, other methods refused, the rate limit (429).
- Stop signal: access rules (only SYSTEM and Administrators when elevated, only the current user when not), a
  name someone else created first (exit 3), one copy's `-Stop` never stopping another copy, the forced stop
  matching only this folder's script.
- Share check: equal, above, below, junctions, a sibling with a shared prefix, whole folder names, case and
  trailing separators, special shares ignored but hidden user shares counted, network paths and mapped drives, an
  unreadable share list. The data folder lock and the permissions fix.
- Cleanup: deletes only regular files with exact-pattern names older than retention by the name's date; never
  links or junctions, never the newest 7 days, nothing when the clock looks wrong.
- Size caps: the 20 MB daily cap on both logs (flags and the stopped line still written), `/stats?since=` at 50
  events, `/events` at 1,000, `history.json` read up to 2 MB, `maintenance.json` up to 4 KB, the Maintenance end
  time held to the maximum.
- Static files: no path traversal out of `web\`, the config file is never served.
- Privacy: a canary player name and stream title never reach any file under `DataPath`.

## 3. Design-for-testability rules for the build

These are requirements on the build, checked in code review and, where marked (S), by `tests\Static.Tests.ps1`.
Without them the coverage targets in section 1 can't be reached.

### 3.1 Where the logic lives

The spec names five modules. Three more are needed to make the rest of the logic in `SRRVRR.ps1` testable (open question OQ1 in section 9; the boot launcher checks every file in `modules\`, so it picks them up):

| Module | Holds | Extracted from today's `SRRVRR.ps1` |
|---|---|---|
| `modules\Counters.psm1` (spec) | Counter deltas, CPU total, GPU engine sums, per-process CPU / GPU / memory / network rows, disk IO per letter, `tickMs`, `Get-TracerLogEntry` | The fast sampler's body |
| `modules\History.psm1` (spec) | `double[]` rings per line with the newest reading's time and a lock, line registration, the hand-built JSON writer, save (tmp and swap), load (size cap, age, version, damage) | New |
| `modules\Events.psm1` (spec) | Event ids, the shared queue, the drain (ids, suppression, writes, publishing a new array), change detection (old state vs new), the JSONL writer, the in-memory index for `/events`, cleanup | New, plus the page's `watchValheim` / `watchPlex` comparisons moved to the server |
| `modules\Logging.psm1` (spec) | Log line format, the once-a-minute throttle, the 20 MB daily cap (flags and the stopped line exempt), the trap's exception formatter | New |
| `modules\Web.psm1` (spec) | `Invoke-SrrRoute` (routing as a plain function), the `Host` allowlist (421), the `POST /maintenance` guard (header, content type, `Origin`), the fixed static path table, method rules (405), `/stats` snapshot building, `?since=` and `?days=` parsing and limits, the Maintenance rate limit | HTTP loop |
| `modules\Settings.psm1` (new) | Defaults, `$retired`, reading the config, validation (old and new settings), `Test-PrivateAddress`, `Test-SingleAddress`, `DataPath` resolution and fallback, the share check, the lock, the permissions plan, Maintenance state and its file, the exit code map | Settings section, firewall address checks |
| `modules\Control.psm1` (new) | Path normalization for the stop event, stop event naming and trust check, the stopper's decision logic, process selection for the forced stop, the firewall rule plan, the listener prefix choice, drive selection for the drives card, the worker watcher's decisions | `-Stop` block, firewall reconcile, slow sampler's drive list |
| `modules\Platform.psm1` (new) | Thin wrappers only: `Get-ShareList`, `Test-Elevated`, `New-StopEvent`, `Open-StopEvent`, `Set-DataFolderAcl`, `Sync-FirewallRule`, `Get-SRRVRRProcessList`, `Get-VolumeInfo`, `Read-CounterCategory` | OS calls |

`SRRVRR.ps1` is the composition root: it reads settings through `Settings.psm1`, wires real dependencies into the
modules, creates the runspaces, and runs the listener loop, which drains the event queue between requests and
calls `Invoke-SrrRoute` for every request, only copying its result to the response.

The two C# exception classes (`SrrSettingsException`, `SrrRefusalException`) are compiled once, early in
`SRRVRR.ps1`, and also by `TestHelpers` for unit tests (the source lives in one place: a here-string the tests read
with `Get-AddTypeSource`, open question OQ1).

### 3.2 Rules

1. **Inject the clock.** No module calls `Get-Date`, `[DateTime]::Now`, `[DateTime]::UtcNow` or
   `[DateTimeOffset]::*Now` directly (S). Pure functions take `-Now` (a `[DateTimeOffset]`); stateful objects
   (`New-HistoryStore`, `New-EventStore`, `New-ErrorThrottle`, `New-DailyLog`) take `-Clock`, a scriptblock that
   returns a `[DateTimeOffset]`, defaulting to `{ [DateTimeOffset]::Now }` set in `SRRVRR.ps1` only. Durations
   are measured with an injectable stopwatch (`-Stopwatch`, default `[Diagnostics.Stopwatch]::StartNew()`), so
   `tickMs` is testable.
2. **Inject the file system root.** Every function that reads or writes data takes `-DataPath` (or `-LogDir`,
   `-StateDir`, `-WebRoot`). No module uses `$PSScriptRoot` except to find its sibling modules (S). Writes go
   through one function, `Write-DataFile -Path -Content` in `Settings.psm1`, which is where a write failure
   triggers the fallback, so the fallback can be tested by pointing it at a read-only folder.
3. **Inject the counter source.** `Counters.psm1` never creates `PerformanceCounterCategory` objects. It takes
   snapshots shaped like `ReadCategory()`'s result (category -> counter -> instance -> `CounterSample`), from a
   reader scriptblock. The real reader is `Read-CounterCategory` in `Platform.psm1`; tests use
   `tests\fakes\FakeCounterReader.psm1`. The same applies to `Get-Process` output (passed in as objects with
   `Id`, `ProcessName`, `TotalProcessorTime`, `WorkingSet64`) and to the tracer's `Drain()` result (passed in as
   a dictionary).
4. **Inject the share list and elevation.** `Test-PathInShare -Path -Shares` and `Resolve-DataPath -Shares
   -IsElevated -TestWritable` take plain data. Only `Platform.psm1` calls `Get-CimInstance Win32_Share`.
5. **Request handlers are plain functions.** `Invoke-SrrRoute -Method -Path -Query -Headers -Body -RemoteAddress
   -LocalPort -Context` returns `@{ Status; ContentType; Body; Headers }` and never touches `HttpListener`
   objects. `-Context` is a hashtable holding the state, the stores and the settings. The listener loop is the
   only code that reads `$ctx.Request` and writes `$ctx.Response`.
6. **No `Write-Host`, `Write-Output` for messages, `exit`, `$global:`, `Read-Host` or `[Console]` in modules**
   (S). Modules return values or throw; messages for the console go back to `SRRVRR.ps1` as data (for example a
   `Notes` list from `Test-SrrSettings`).
7. **Exit codes through one function.** Modules throw `SrrSettingsException` (exit 2) or `SrrRefusalException`
   (exit 3), the spec's C# classes. `Get-SrrExitCode -ErrorRecord` maps an error to its code by exception type,
   looking through `InnerException` and PowerShell's wrapping (anything else: 1). `SRRVRR.ps1` has one function, `Exit-SRRVRR -Code -Reason`, that writes the last log
   line ("stopped: <reason> (exit <code>)") and calls `exit`. `Static.Tests.ps1` checks that `exit` appears in
   `SRRVRR.ps1` only inside `Exit-SRRVRR` and the `-Stop` block (S).
8. **Limits are parameters with the spec's defaults:** ring size 900, store size 200, suppression 10 minutes,
   throttle 60 s, daily cap 20 MB, stop wait 10 s, history max age 15 minutes, save interval 5 minutes, `since`
   limit 50, `/events` limit 1,000, history read cap 2 MB, Maintenance read cap 4 KB, rate limit 10 s and 60 a day,
   cleanup floor 7 days, launcher-facing marker window 60 s. Tests pass small values (a 2 KB cap, a 5-slot ring) to stay fast; one test per
   limit checks the default value.
9. **Modules load by full path.** `SRRVRR.ps1` imports `Join-Path $PSScriptRoot 'modules\<Name>.psm1'`, and each
   runspace gets the same full paths through `InitialSessionState.ImportPSModule`. No `Import-Module <Name>`
   without a path, no `#Requires -Modules`, no use of `$env:PSModulePath` (S).
10. **The runspace loops are thin.** Each loop body is one call: `Invoke-FastTick -State -Reader ...` and
    `Invoke-SlowTick -State -Tick ...`, defined in modules, with a `try/catch` that hands the error to the
    throttled log. Any branch inside the loop beyond "call, catch, sleep" belongs in the module (review rule).
11. **The page's logic is testable without a browser.** `web\app.js` keeps its pure functions (`shouldBanner`,
    `nextSince`, `rangeFromStorage`, `bits`, `size`, `speed`, `since`, `plexRes`, ...) free of DOM access and ends
    with `if (typeof module !== 'undefined') { module.exports = { ... }; }`, so `node --test` can load it. The DOM
    code calls them.
12. **The C# stays C# 5 and reports, never throws, across the callback.** `ProcessNetTrace` wraps its callback
    and thread body in `try/catch` and keeps the last error's text and type, an error count and a thread-alive
    flag in public static fields. The fast sampler reads them through `Get-TracerLogEntry -Current -LastLogged`
    (pure, in `Counters.psm1`), so what gets logged is unit-tested.
13. **Static files come from a fixed table.** `Get-StaticRoute -UrlPath` returns one of `/`, `/app.js`,
    `/style.css`, or `/img/<name>` with `<name>` matching `^[a-z0-9-]+\.(svg|png)$`, each with its fixed file and
    content type; anything else is `$null` (404). The file path is never built from more of the URL than that
    checked name.
14. **Saved files carry a format version and their own times** (`history.json`: `version`, `newestMs`, `stepMs`;
    `maintenance.json`: `version`, `on`, `untilMs`), and loaders decide on those, not the file's modified time, so
    tests don't need to change file times.
15. **Cross-thread work goes through the shared queue.** Samplers and the web code only call
    `Add-SrrQueueItem` (event or error). `Invoke-QueueDrain -Queue -Store -Writers -Clock` does ids, suppression,
    throttling, writes and publishing, and is called by the main loop; tests call it directly.
16. **Wait points are functions.** The request loop and every `Set-Step` call `Test-StopSignal`, which tests mock
    to simulate a stop arriving at a given step.
17. **Which copy am I** is one function, `Get-SrrCopyKind -Folder` (`live` or `test`), so the firewall names and
    the stop event follow from it in tests (open question OQ2: how a test copy is recognized).

## 4. Reusable test assets in the repo

All paths are relative to the repo root. Everything under `tests\`, `tools\`, `docs\` and `.github\` is
`export-ignore`, so none of it ships in a release. "Copyable" marks assets with nothing SRRVRR-specific in them,
which other PowerShell 5.1 repos can take as they are.

### 4.1 Test infrastructure

| Path | What it does | Copyable |
|---|---|---|
| `tests\TestHelpers.psm1` | Imported by every test file (`BeforeAll { Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force }`). Functions below. | Mostly (the `*-TestBuild` functions are SRRVRR's) |
| `tests\PesterConfiguration.psd1` | The one Pester 5 configuration: `Run.Path = tests`, `TestResult` (NUnitXml to `out\test-results.xml`), `CodeCoverage` (paths `modules\*.psm1` and `tools\SRRVRR.Tools.psm1`, JaCoCo to `out\coverage.xml`, `CoveragePercentTarget = 100`, `UseBreakpoints = $false`), `Output.Verbosity = Detailed`. `Invoke-Checks.ps1` loads it with `New-PesterConfiguration -Hashtable` and overrides tags | Yes |
| `tools\Invoke-Checks.ps1` | The one entry point, used locally and by CI. Parameters: `-Level Static,Unit,Integration` (default), `-Smoke`, `-Elevated` (refused unless on CI), `-Coverage`, `-CI` (fails on coverage below target once required). Steps: import the pinned versions first thing (`Import-Module Pester -RequiredVersion <x>` and `Import-Module PSScriptAnalyzer -RequiredVersion <y>`, the versions written once at the top; removing an autoloaded 3.4 first; a plain message and exit 2 if the pinned version isn't installed, so the built-in Pester 3.4 is never used by mistake), run `Test-Parse.ps1` and `Test-Ascii.ps1`, run PSScriptAnalyzer, run Pester, run `node --test tests\js` if `node` is found (required with `-CI`), write a summary table to the console and `out\summary.md`. Exit code: 0 all passed, 1 failures | Yes (paths at the top) |
| `tools\Test-Ascii.ps1` | Lists every non-ASCII byte in `*.ps1`, `*.psm1`, `*.psd1`, `*.bat` with file, line and column; exit 1 if any. `web\` is skipped (may be UTF-8). Also checks `.bat` files are CRLF | Yes |
| `tools\Test-Parse.ps1` | Parses every `*.ps1` / `*.psm1` / `*.psd1` with `[Management.Automation.Language.Parser]::ParseFile`, then compiles every `Add-Type -TypeDefinition` block it finds (the network tracer, the exception classes, the temperature reader) in a child `powershell.exe`, so C# 6+ syntax fails here and not at start; prints errors with line numbers; exit 1 if any | Yes |
| `tools\Test-NoPrivateInfo.ps1` | Scans tracked files (`git ls-files`) for IPv4 addresses outside the documentation ranges and private examples on an allow list, UNC paths, drive-letter paths, e-mail addresses, and any word in an optional local deny list (`$env:SRRVRR_DENYLIST` or `.git\info\private-words.txt`, never committed). Exit 1 with file and line | Yes |
| `tools\Test-PathLength.ps1` | Fails if any runtime file under a given root would exceed 259 characters (the long path limit on these machines) | Yes |
| `tools\PSScriptAnalyzerSettings.psd1` | Rules for all code (`PSUseCompatibleSyntax` for 5.1, `PSAvoidUsingInvokeExpression`, `PSAvoidGlobalVars`, `PSUseDeclaredVarsMoreThanAssignments`, ...). `PSAvoidUsingWriteHost` is excluded for `SRRVRR.ps1` and `tools\` only (console UI); modules get it as an error | Yes |
| `tools\SRRVRR.Tools.psm1` | Shared code for the tools: percentile, budget comparison, process lookup by folder (HttpListener's port is owned by the System process, so the port can't identify SRRVRR), git archive extraction. Unit-tested to 90% | Partly |
| `tools\budgets.psd1` | The spec's budget table as data: `ProcessCpuPercentOfMachineMax = 1`, `MemoryVsPreviousReleaseMBMax = 25` (private bytes after 60 minutes), `StatsP95MsMax = 30` (also under `/history` and `/events` load), `HistoryMsMax = 50`, `EventsMsMax = 50`, `PageLoadMsMax = 150`, `StartupSecondsMax = 20`, `DiskWriteMBPerDayMax = 100`, `TickMedianTolerance = 10%` or 5 ms of `TickMsBaseline`, plus the v0.6.0 baseline values. `TickMsBaseline` and each release's memory figure are filled in from measurements (#47 for the tick) | Pattern |

**`tests\TestHelpers.psm1` functions:**

| Function | Does |
|---|---|
| `New-FakeClock -Start <DateTimeOffset>` | Object with `.Now()`, `.Advance([TimeSpan])`, `.AdvanceSeconds(n)`, `.Set(t)` and `.Clock` (a scriptblock for `-Clock` parameters). Starts at a fixed date that crosses no daylight-saving change unless asked |
| `New-TestDataPath` | Creates `$env:TEMP\srrvrr-tests\<guid>` with `state\` and `logs\`; returns the path; `Remove-TestDataPath` deletes only folders under `srrvrr-tests` |
| `New-ReadOnlyFolder` / `Remove-ReadOnlyFolder` | A folder the current user can't write (deny-write ACE for the current user), for fallback tests; removes the ACE before deleting |
| `Get-FreePort` | Binds a `TcpListener` to `127.0.0.1:0`, reads the port, releases it; skips 8091 and any port in `-Exclude` |
| `Start-TestServer -Context -Port` / `Stop-TestServer` | Runs a real `HttpListener` on `http://localhost:<port>/` in a background runspace that calls `Invoke-SrrRoute` for each request: the production router behind a real socket, without starting SRRVRR. Retries once on a port clash |
| `Invoke-TestRequest -Method -Url -Headers -Body` | `HttpWebRequest` wrapper that returns `@{ Status; Headers; Body; Json; Ms }` and never throws on 4xx/5xx (PowerShell 5.1's `Invoke-WebRequest` throws and needs IE settings) |
| `Read-JsonLines -Path` | Returns each line as an object; reports bad lines as `@{ Line; Error }` instead of throwing |
| `ConvertTo-JsonShape -Json` | Reduces a JSON document to its key paths and types (`services[].cpu: number`), for parity checks |
| `Wait-Until -Condition -TimeoutSeconds -IntervalMs` | Polls; throws with the last value on timeout |
| `Get-ScriptAst -Path` / `Get-HereString -Path -Variable` / `Get-AddTypeSource -Path -TypeName` | Read `SRRVRR.ps1` (or an old version from `git show`) without running it: the page here-string of v0.6.0, the C# source of `ProcessNetTrace` |
| `Invoke-InChildPowerShell -Script -TimeoutSeconds` | Runs a script in a new `powershell.exe -NoProfile` (needed for `Add-Type`, which can't be unloaded), returns output and exit code |
| `New-TestBuild` / `Start-TestBuild` / `Stop-TestBuild` | Wrap `tools\New-TestBuild.ps1`; start the copy unelevated as a child process with `-PassThru`; stop it with its own `-Stop` and return the exit code; always kill leftovers in `AfterAll` (only processes whose command line points into the test build's folder) |
| `Assert-NoCanary -Root -Words` | Fails if any file under `Root` contains one of the canary words (player name, stream title, process name) |
| `New-FakeShareList` | Share objects (`Name`, `Path`, `Type`) from a short list, including special shares (type bit 0x80000000) and hidden user shares |
| `New-TestJunction -Path -Target` | A directory junction (`mklink /J` needs no administrator), removed in `AfterAll` without touching the target |
| `New-SquattedStopEvent -Folder -Everyone` | Creates the copy's `Local\` stop event name first with an open access rule, to test the taken-name refusal; returns a handle to close |
| `Lock-TestDataPath -DataPath` | Holds `state\srrvrr.lock` open exclusively, as a running copy would |

### 4.2 Fixtures (`tests\fixtures\`)

All fixtures are made-up data: no real names, titles, addresses or paths from the owner's machines. Drive
letters in fixtures are arbitrary.

| Path | Contents | Used by |
|---|---|---|
| `tests\fixtures\stats\v0.6.0-shape.json` | Key paths and types of v0.6.0's `/stats`, produced once with `ConvertTo-JsonShape` from a real response with values removed | #47 parity, every later PR |
| `tests\fixtures\stats\v0.7.0-sample.json` | A full `/stats` with `tickMs`, `maintenance` and three events | JS tests, `/stats` contract tests |
| `tests\fixtures\history\good.json` | `version: 1`, `newestMs` = fixture time, `stepMs: 1000`, five lines of 900 numbers with a few `null`s | History load |
| `tests\fixtures\history\stale.json` | Same, `newestMs` 15 minutes and 1 second before the fixture time (plus `edge.json` at 14:59) | Age check |
| `tests\fixtures\history\damaged.json` | Cut off mid-array | `.bad` rename |
| `tests\fixtures\history\unknown-version.json` | `version: 99`, otherwise valid | Version check, rollback |
| `tests\fixtures\history\wrong-types.json` | Valid JSON with strings and nested objects in the arrays | "Numbers only" |
| `tests\fixtures\history\oversize.json` | Generated at test time (not committed): 2 MB + 1 byte, and exactly 2 MB | Size cap |
| `tests\fixtures\maintenance\on.json`, `expired.json`, `far-future.json` (`untilMs` a year ahead), `damaged.json`, `unknown-version.json`, plus a generated 4 KB + 1 byte file | Maintenance state files | Maintenance load, clamp, size cap |
| `tests\fixtures\events\events-good.jsonl` | 20 events across severities, one with `maintenance: true` | `/events`, Flagged list |
| `tests\fixtures\events\events-bad-lines.jsonl` | Good lines plus an empty line, a non-JSON line and a cut-off last line | Reader robustness |
| `tests\fixtures\logs\names.txt` | File names for the cleanup test: matching old, matching new, look-alikes (`events-2026-01-01.jsonl.bak`, `events-2026-1-1.jsonl`, `Events-2026-01-01.jsonl` (case), `events-2026-01-01.log` (wrong pairing is still matched by the spec's pattern, so it's listed to pin that), `srrvrr-2026-13-40.log`, `notes.txt`, `history.json`), created at test time in a temp `logs\` folder, plus a junction and a symbolic link with matching names | Cleanup |
| `tests\fixtures\counters\*.json` | Pairs of counter snapshots (previous, current) as raw values, base values, frequencies, timestamps and counter types, with the expected results: CPU `_Total`, GPU engines for two adapters, network adapters, disk instances (letters, volumes, `_Total`), process IDs and private working sets | Counters |
| `tests\fixtures\processes\*.json` | Process lists (id, name, CPU seconds, working set) for Valheim and Plex present, missing, and exiting between reads | Per-process rows |
| `tests\fixtures\cmdlines\*.json` | Process command lines for `-Stop`: quoted and unquoted `-File` paths, spaces, two copies in two folders, the legacy test file name, a `-Stop` process, the caller's own id | Process selection |
| `tests\fixtures\drives\*.json` | Volumes (`Win32_Volume`, including a folder mount point) and disk health: fixed, removable holding `DataPath`, a data drive under 1 GB, a missing data drive, health `Unknown` | Drives card |
| `tests\fixtures\config\*.psd1` | One valid config per new setting's boundary, one invalid per rule, a config that doesn't parse, a legacy-named file | Settings, exit code 2 |
| `tests\fixtures\activity\*.json` | Valheim and Plex activity before and after (joins, leaves, new stream, offline, query errors) with canary names | Event detection, privacy |

### 4.3 Fakes (`tests\fakes\`)

| Path | Does |
|---|---|
| `tests\fakes\FakeCounterReader.psm1` | `New-FakeCounterReader -Snapshots <fixture>` returns a reader scriptblock that hands out the snapshots in order, building real `System.Diagnostics.CounterSample` values (it has a public constructor), and can be told to throw on the Nth read |
| `tests\fakes\FakeShareList.psm1` | `New-FakeShareList` (also re-exported by `TestHelpers`): disk shares, hidden user shares (name ending in `$` but not administrative), administrative shares (`ADMIN$`, `IPC$`, drive-root shares) |
| `tests\fakes\FakeProcessSource.psm1` | Process lists from `tests\fixtures\processes\`, with exiting processes that throw on `TotalProcessorTime` |
| `tests\fakes\FakeLauncher.ps1` | A reference implementation of the launcher contract (spec, Dependencies and section 5): starts a script, restarts only on crash codes, at most 3 times in 10 minutes, treats an exit within 60 s of `state\stop-requested` as requested and deletes the marker; logs each decision. Driven by stub scripts that exit with a given code. The launcher project can copy it as its own test oracle |
| `tests\fakes\FakeStatsServer.ps1` | A tiny `HttpListener` that serves a fixed `/stats` (and `/history`) from a fixture, for testing `tools\Measure-SRRVRR.ps1` and `tools\Invoke-UatChecks.ps1` without SRRVRR |

### 4.4 Tools that also serve the owner

| Path | Does |
|---|---|
| `tools\New-TestBuild.ps1` | `-Ref <branch or tag> -Destination <folder> [-Port 8091] [-DataPath <folder>] [-LiveFolder <folder>] [-Force]`. Runs `git archive --format=zip <ref>` (so only runtime files, by `export-ignore`) and expands it into `Destination`; writes a test config (`Port`, `DataPath`, `Processes` as in the example); marks the folder as a test copy (OQ2); writes `TESTBUILD.txt` with the ref, commit and time. Refuses: a destination inside `-LiveFolder` (or `$env:SRRVRR_LIVE_FOLDER`), a non-empty destination without `-Force`, `-Force` on a folder without `TESTBUILD.txt`, paths that `Test-PathLength.ps1` rejects. Never reads or copies the live config |
| `tools\Measure-SRRVRR.ps1` | `-BaseUrl -Folder [-Seconds 60] [-SoakMinutes 0] [-Budgets tools\budgets.psd1] [-OutFile]`. Read-only: SRRVRR's own CPU as a percentage of the whole machine over the window (process found by folder; `% Processor Time` of that process / logical CPUs), its private bytes (at start, at the end, and after 60 minutes with `-SoakMinutes 60`), `/stats` median and p95 over 120 requests both idle and while a second thread requests `/history` and `/events` in a loop, `/history` and `/events?days=31` times, `/stats` size, page load (`/` plus its assets), `tickMs` median and max from `/stats` (compared with the baseline: within 10% or 5 ms), startup time (when given `-StartedAt`, or read from the crash log's first and "serving" lines), disk writes (growth of `state\` and `logs\` over the window, scaled to a day; process write bytes as an upper bound). Prints a markdown table with the budget and the baseline beside each number, for the PR description; exit 1 if a budget is exceeded (exit 0 with `-Informational`) |
| `tools\Invoke-UatChecks.ps1` | `-Story 47..51 -BaseUrl -Folder`. Runs the read-only checks for one story's checklist (fields in `/stats`, the history file's age and size, the last lines of today's logs, the newest events, the Maintenance state, the drives card's entries) and prints pass / fail / "look" lines matching the checklist's numbers |
| `docs\uat\47-foundation.md` ... `docs\uat\51-readme.md` | One checklist per story: setup (build the test copy), numbered steps, what to look for, which steps `Invoke-UatChecks.ps1` checks for you, and a results block to paste into the PR. About 15 minutes each |

### 4.5 Notes on reuse

- **Copyable as they are:** `Test-Ascii.ps1`, `Test-Parse.ps1`, `Test-NoPrivateInfo.ps1`, `Test-PathLength.ps1`,
  `PSScriptAnalyzerSettings.psd1`, `PesterConfiguration.psd1`, `Invoke-Checks.ps1`, and the generic half of
  `TestHelpers.psm1` (clock, temp folders, free port, HTTP helpers, JSONL reader, `Wait-Until`, AST helpers,
  child process runner, canary check). If two or more repos adopt them, they can move into their own module
  with a version, copied into each repo (a vendored copy, not a dependency fetched at test time).
- **Reusable workflows:** a public repo can't call a reusable workflow kept in a private repo. If the owner wants
  one shared CI workflow, it has to live in a public repo (or be copied into each repo). This plan keeps
  SRRVRR's workflow self-contained.
- **Checklists** follow one template (`docs\uat\_template.md`) so other projects can copy the format.

## 5. CI

File: `.github\workflows\checks.yml` (spec section 1). Every step runs in **Windows PowerShell 5.1**
(`shell: powershell`), never `pwsh`, because 5.1 is what SRRVRR runs on.

**Triggers:** `pull_request` (all branches, so stacked PRs are checked), `push` to `main`, and
`workflow_dispatch`. **Permissions:** `contents: read` only. **Runner:** a pinned Windows image (for example
`windows-2022`), not `windows-latest`, so an image change doesn't silently change results; bump it in its own PR.
Third-party actions are pinned to a full commit SHA. **Concurrency:** one run per branch, newer cancels older.

| Job | Steps | Needs | Time |
|---|---|---|---|
| `static` | Checkout; `tools\Test-Parse.ps1` (including compiling every `Add-Type` block); `tools\Test-Ascii.ps1`; `tools\Test-NoPrivateInfo.ps1`; `tools\Test-PathLength.ps1 -Root .` | - | 1 min |
| `analyze` | Checkout; restore the module cache; install PSScriptAnalyzer at a pinned version (`Install-Module -Scope CurrentUser -RequiredVersion <x> -Force`, after `Install-PackageProvider NuGet -Force` and TLS 1.2, which 5.1 needs); `Invoke-ScriptAnalyzer -Recurse -Settings tools\PSScriptAnalyzerSettings.psd1`; upload the findings as SARIF (`out\psscriptanalyzer.sarif`) | - | 2 min |
| `test` | Checkout (full history, for the parity test's `git show`); restore the module cache; install Pester at a pinned 5.x version the same way; `tools\Invoke-Checks.ps1 -CI -Coverage -Level Static,Unit,Integration,Elevated -Smoke` (its first lines are the `Import-Module ... -RequiredVersion` calls, so CI and local runs use the same pinned versions); `node --test tests\js` (Node is on the runner image); upload `out\test-results.xml`, `out\coverage.xml`, `out\summary.md` as the `test-results` artifact (always, also on failure); write `out\summary.md` to the job summary | - | 5 min |
| `measure` | Build a test copy with `tools\New-TestBuild.ps1 -Ref HEAD`; start it; `tools\Measure-SRRVRR.ps1 -Informational -Seconds 30`; upload the table; stop the copy and check exit code 0 | `test` | 3 min |

**Elevated tests in CI.** GitHub's Windows runners run as an administrator on a machine that's thrown away after
the job, so the `Elevated` tests (firewall rules, the machine-wide stop event and its access rules, a real share,
the ETW session) run there and only there. `Invoke-Checks.ps1 -Elevated` refuses unless `$env:GITHUB_ACTIONS` is
`true` and the process is elevated, so they can't run on the dev PC or the server by mistake.

**Advisory, then required.**

| Stage | When | What fails the check |
|---|---|---|
| Advisory | From #47 until the checks have passed on three PRs in a row (spec section 7) | Nothing blocks merging. The jobs still report red/green; coverage is reported, not enforced. `continue-on-error: true` on the jobs. `out\summary.md` keeps a "green streak" line the owner can read |
| Required | After the third green PR in a row | `static`, `analyze` (errors only) and `test` become required status checks on `main` (branch protection, set by the owner). Coverage enforced: modules 100% commands. Tool module 90% stays advisory. A red run before that resets the streak |
| Informational, always | - | `measure` (shared hardware). Lowering any target needs a note in the PR and an update to this plan |

Turning a stage on is one change: removing `continue-on-error` and passing `-CI` thresholds; the owner adds the
required checks in the branch protection settings.

**What CI can't do:** it can't measure the budgets on the server's hardware (the owner's local run does, section
8), can't open the page on two PCs, and can't reach the owner's machines (it never should).

## 6. Test cases per story

**How to read the tables.** `Req` uses the requirement ids from section 7. `Lvl`: S static, U unit, J JS unit, I
integration, E elevated integration (CI only), K smoke on a test build, P performance, A owner UAT; a trailing X
marks a security / negative test. `Asset` names what the test uses: TH `tests\TestHelpers.psm1`, CLK fake clock,
FCR fake counter reader, FSL fake share list, FPS fake process source, FSS fake stats server, FX
`tests\fixtures\...`, NTB `tools\New-TestBuild.ps1`, MS `tools\Measure-SRRVRR.ps1`, UC `tools\Invoke-UatChecks.ps1`.
Every Pester `It` starts with its id (`It 'T48-07 refuses a fallback folder inside a share'`), so
`Traceability.Tests.ps1` can find it. Test file per area: `Counters.Tests.ps1`, `History.Tests.ps1`,
`Events.Tests.ps1`, `Logging.Tests.ps1`, `Settings.Tests.ps1`, `Server.Tests.ps1`, `Static.Tests.ps1`,
`Parity.Tests.ps1`, `Smoke.Tests.ps1`, `Elevated.Tests.ps1`, `Tools.Tests.ps1`, `Traceability.Tests.ps1`, and
`tests\js\app.test.js`.

Where a case says "pinned", the expected value is this plan's proposal for something the spec leaves open; the
matching question is in section 9, and the test changes if the owner decides otherwise.

### 6.1 #47 Foundation, no change in behavior

| Id | Req | Lvl | Inputs | Expected | Asset |
|---|---|---|---|---|---|
| T47-01 | F1 | S | Repo tree | `modules\Counters.psm1`, `web\index.html`, `web\app.js`, `web\style.css`, `web\img\`, `tests\`, `tools\Measure-SRRVRR.ps1`, `.github\workflows\checks.yml` exist | - |
| T47-02 | F4 | S | All `*.ps1`, `*.psm1`, `*.psd1`, `*.bat` | No non-ASCII byte; `.bat` files are CRLF; `web\index.html` declares `charset=utf-8` | Test-Ascii |
| T47-03 | F4, Q2 | S | Same files | Parser reports no errors | Test-Parse |
| T47-04 | F2 | S | `SRRVRR.ps1` AST; `Stop SRRVRR.bat`; `Start SRRVRR.bat` | `param()` has exactly `Port` (int) and `Stop` (switch); the .bat files still call `SRRVRR.ps1` by the same relative path | TH (AST) |
| T47-05 | F6, DEP3 | I | `git archive --format=zip HEAD`, listed | No entry under `tests/`, `tools/`, `docs/`, `.github/`, and no `.gitattributes` or `.gitignore`; contains `SRRVRR.ps1`, every `modules/*.psm1`, every `web/` file, the .bat files, the config example, `Install-TemperatureSensors.ps1` | - |
| T47-06 | F7 | I | `git check-ignore state/history.json logs/srrvrr-2026-01-01.log SRRVRR.config.psd1` | All three ignored | - |
| T47-07 | F1 | S | `SRRVRR.ps1` AST | Number of `Set-Step` calls equals `Steps`; the last `Set-Step` is `'Reticulating Splines...'` | TH (AST) |
| T47-08 | F5 | S | `SRRVRR.ps1` and module ASTs | Every `Import-Module` is `Import-Module -Name <full path> -Force` with the path built from SRRVRR's own folder and `modules\`, and each runspace script starts with its imports; no import by bare name; no `$env:PSModulePath`; no `#Requires -Modules` | TH (AST) |
| T47-09 | F1 | S | Module ASTs | No `Write-Host`, `exit`, `$global:`, `Read-Host`, `[Console]`, `Get-Date`, `[DateTime]::Now`/`UtcNow`, `[DateTimeOffset]::Now`/`UtcNow` in any module (section 3, rules 1 and 6) | TH (AST) |
| T47-10 | F5, SEC4 | K X | Test build started with `$env:PSModulePath` pointing at a decoy folder holding a `Counters` module that writes a canary file on import | Copy serves `/stats`; canary file never created | NTB, TH |
| T47-11 | F1 | U | Counter snapshot pairs (CPU) | `_Total` CPU equals the fixture's expected value to 0.1; first snapshot (no previous) gives no values; an instance missing from the previous snapshot is skipped; result capped at 100 | FCR, FX counters |
| T47-12 | F1 | U | GPU engine snapshots for two adapters | Engines summed across processes; busiest engine and its type reported; the other adapter's LUID excluded; no `GPU Engine` category gives 0 and `''`; GPU memory summed for the chosen LUID only | FCR, FX counters |
| T47-13 | F1 | U | Process lists + snapshots | Per-row CPU % = CPU seconds / (elapsed x cores), capped at 100; `coresUsed`; memory % uses private working set, falling back to `WorkingSet64`; row `online = $false` when the main process is missing; a process that throws on `TotalProcessorTime` is skipped, not fatal; `tx`/`rx` null without the tracer, bytes per second with it | FPS, FCR |
| T47-14 | F1, F8 | I | `Invoke-FastTick` in a real runspace (module imported by full path), fake reader | State becomes `ready` with `ts` and `tickMs`; when the reader throws on the 3rd read, `state.error` is set and the 4th tick succeeds and clears it | FCR, TH |
| T47-15 | F1 | U | Disk and network snapshots | Only letter instances (`X:`) in `diskIO`, uppercased; `HarddiskVolume*` and `_Total` excluded; network rx/tx summed over adapters | FCR |
| T47-16 | B9, D1 | U | Fake stopwatch reading 37.4 ms | `tickMs` = 37 (number, rounded) in the state; with no tick yet, `tickMs` is `null` (pinned) | CLK |
| T47-17 | D6, DEP1 | I | `/stats` from the router with a fixture state | Its shape contains every key path and type in `v0.6.0-shape.json`; the only new path is `tickMs: number` | FX stats, TH |
| T47-18 | D6, DEP1 | K | v0.6.0 tag and HEAD built side by side with NTB on two free ports | Same `/stats` shape apart from `tickMs`; same `Content-Type` and `Cache-Control: no-store` on `/` and `/stats` | NTB, TH |
| T47-19 | F1 | U | v0.6.0's `$html` here-string (via `git show v0.6.0:SRRVRR.ps1`) and HEAD's `web\` files | Same set of element ids; script text equal to `app.js` after whitespace normalization (ignoring the `module.exports` tail); CSS equal to `style.css` after normalization; every `data:` image in the old page decodes to the same bytes as a file in `web\img\` that the new page references in the same place | TH (AST, here-string) |
| T47-20 | F3 | I | GET `/`, then each asset `index.html` references | 200 each; fixed content types `text/html; charset=utf-8`, `application/javascript`, `text/css`, `image/png` / `image/svg+xml`; every one has `X-Content-Type-Options: nosniff`; total page size reported | TH (test server) |
| T47-21 | F3 | I | Temp web root; GET `/`; edit `index.html`; GET `/` | Second response has the edit, without a restart | TH |
| T47-22 | W1, SEC4 | U X | `Get-StaticRoute` with `/../SRRVRR.ps1`, `/%2e%2e/SRRVRR.config.psd1`, `/img/..%5c..%5cSRRVRR.config.psd1`, `/img/%2e%2e%2fx.png`, `/img/A.png` (upper case), `/img/a_b.png`, `/img/a.png.exe`, `/img/a.gif`, `/img/`, `/app.js/`, `/web/app.js`, a NUL character, a 4 KB path | `$null` (404) for each; for the good names, the file is exactly `web\img\<name>`; no file read happens for a refused path (Mock on the reader, `-Times 0`) | - |
| T47-23 | W2 | I | GET `/anything-else`, `/stats/`, `/index.html` | 404 with a plain body (the spec's one intended change from v0.6.0, where every unknown path returned the page) | TH |
| T47-36 | W3, SEC2 | I X | `POST`, `PUT`, `DELETE`, `HEAD`, `OPTIONS` on `/`, `/stats`, `/app.js`, `/img/<good>.png`; `OPTIONS /maintenance` with `Access-Control-Request-Method: POST` | 405 each (`OPTIONS /maintenance` included); no response ever carries an `Access-Control-*` header (checked on every response in the whole suite by a shared `AfterEach` in `Server.Tests.ps1`) | TH |
| T47-37 | W4 | I | Temp web root with `app.js` missing, and with `style.css` locked for reading | 500 with a plain message; one error-log line naming the file; the next request still works | TH |
| T47-38 | W5, SEC2 | U X | `Test-HostAllowed` with the allow list built from a fake machine identity (name, full DNS name, two IPv4, one IPv6): each of those with the port; `localhost`, `127.0.0.1`, `[::1]` with the port; the same names with another port or no port; `evil.example:<port>`; an IP of another machine; upper-case name; a trailing dot; an empty `Host` | Allowed / allowed / refused / refused / refused / allowed (case-insensitive) / refused (pinned; OQ4) / refused | - |
| T47-39 | W5, DEP1 | I X | GET `/stats`, `/` and `/app.js` with `Host: evil.example:<port>` (DNS rebinding) | 421 with an empty body and no other headers beyond the minimum; a normal `Host` still gets 200 | TH |
| T47-40 | F9 | K | Test build whose files all carry the downloaded-from-the-internet mark (a `Zone.Identifier` stream with `ZoneId=3`), started the way `Start SRRVRR.bat` starts it (`-ExecutionPolicy Bypass`) | Starts and serves; every module loads in every runspace (no security prompt or error in the log) | NTB, TH |
| T47-24 | Q2 | S | PSScriptAnalyzer with `tools\PSScriptAnalyzerSettings.psd1` | No errors; warnings listed | PSSA |
| T47-25 | Q2 | S | `.github\workflows\checks.yml` as text | Jobs `static`, `analyze`, `test`, `measure`; `shell: powershell` and no `pwsh`; `permissions: contents: read`; artifacts uploaded with `if: always()`; actions pinned to SHAs | - |
| T47-26 | B9 | U | Percentile, budget comparison, process-by-folder lookup in `SRRVRR.Tools.psm1` | p50/p95 of known lists correct; over / equal / under budget classified; of two fake processes in two folders, only the one in `-Folder` is picked | - |
| T47-27 | B9 | I | `Measure-SRRVRR.ps1` against the fake stats server | Every budget row present in the table; exit 0 with `-Informational`; makes no request other than GET | FSS |
| T47-28 | B1-B6 | P | Test build on port 8091, 60 s | Within budgets (SRRVRR's own CPU at most 1% of the machine; `/stats` p95 30 ms; page 150 ms; start 20 s); `tickMs` median recorded in `tools\budgets.psd1` as `TickMsBaseline`, which later PRs must stay within 10% or 5 ms of; table in the PR | NTB, MS |
| T47-29 | ST7 | U | Configs for every existing rule | `ValheimPort` 0 / 1 / 65534 / 65535; `FirewallScope` values; Allowlist / Blocklist without addresses; private blocks and their edges (172.15.x, 172.32.x rejected, 172.16.0.0/12 accepted, 10.0.0.0/7 rejected, fe80::/9 rejected, fc00::/7 accepted); public addresses only with Allowlist plus `AllowPublicAddresses`, single IPs only, `0.0.0.0` and broadcast rejected; retired keys give a note; unknown keys a warning; the legacy file name is read when it's the only one | FX config |
| T47-30 | F2 | U | Config `Port = 8099`, `-Port 8091` | 8091 used | FX config |
| T47-31 | F1 | J | `bits`, `niceMax`, `since`, `size`, `speed`, `plexRes`, `plexDevice` with table cases | Same outputs as the v0.6.0 functions for the same inputs (golden values captured once) | tests\js |
| T47-32 | DEP4, Q2 | S | Every `Add-Type -TypeDefinition` block in `SRRVRR.ps1` and the modules, compiled by `Test-Parse.ps1` in a child Windows PowerShell 5.1; plus a deliberately bad block (C# 6 string interpolation) in a temp file | All real blocks compile (C# 5 compiler); the bad one is reported with its file and line; `ProcessNetTrace.Drain()` returns an empty dictionary | TH (child process) |
| T47-33 | Q1 | S | This plan's section 7 table and the test files | Every test id in the table exists as an `It` prefix or a UAT checklist step; no `It` without an id | Traceability.Tests.ps1 |
| T47-34 | Q4 | S | `CHANGELOG.md`, `README.md` on the PR branch | An `[Unreleased]` entry exists; README mentions `modules\` and `web\` (advisory) | - |
| T47-35 | B8, Q3, W2 | A | `docs\uat\47-foundation.md` | The page on the test build looks and behaves like the live one side by side: graphs, tiles, drives, Processes table, Valheim and Plex banners (still page-side in #47), sound toggle; `Invoke-UatChecks.ps1 -Story 47` all pass | UC |

### 6.2 #48 Running safely

Events raised here (the fallback, a share appearing, the data drive missing, a worker stopping) go to the status
line and the crash log in #48; their event-log side is tested in #50 (T50-13, T50-14).

**Share check and data folder**

| Id | Req | Lvl | Inputs | Expected | Asset |
|---|---|---|---|---|---|
| T48-01 | P3, SEC6 | U X | A share whose folder equals the data folder | Refuse (`SrrRefusalException`, exit 3) naming the data folder | FSL |
| T48-02 | P3, SEC6 | U X | A share on a folder above the data folder (parent, and grandparent) | Refuse | FSL |
| T48-03 | P3, SEC6 | U X | A share on a folder below the data folder (`state\`, `logs\`, and an unrelated subfolder two levels down) | Refuse in each case | FSL |
| T48-04 | P3 | U X | Share `<root>\Log` with data folder `<root>\Logs`; share `<root>\Data` with `<root>\DataX`; share `<root>\Logs` with `<root>\logs\` | No match, no match, match (whole folder names, case-insensitive, trailing separator ignored) | FSL |
| T48-05 | P3 | I X | Data folder reached through a junction whose target is under a shared folder; data folder that is itself a junction to a shared folder; share path written with `..` and `/` | Refuse each time (both sides resolved with junctions followed before comparing) | FSL, TH (junction) |
| T48-06 | P3 | U X | Shares with the 0x80000000 type bit (`ADMIN$`, `IPC$`, a drive-root share) covering the data folder; a user-made hidden share `Data$` without the bit | Special shares ignored (start allowed); the hidden user share counts (refuse) | FSL |
| T48-07 | P3, ST1 | U X | Data folder on a mapped network drive (fake drive type 4); SRRVRR's own folder on a mapped drive while it's the fallback; own folder on a UNC path | Refuse with exit 3 in each case (a UNC `DataPath` setting itself is a settings error, T48-24) | Mock |
| T48-08 | P3 | U X | Share list read throws; elevated, then unelevated | Elevated: refuse (exit 3) with a plain message. Unelevated: a warning on the console and in the log, start goes on | Mock |
| T48-09 | P3, X3 | E X | Runner: a real share (`New-SmbShare`) above a test build's `DataPath`; then one below it | Exit 3 both times; one plain console line; "stopped: refused ... (exit 3)" as the last line in the own folder's `logs\`; shares removed in `AfterAll` | NTB |
| T48-10 | P3, P10 | U | The share check schedule: at start on `DataPath` and on the fallback folder; daily in the slow sampler with a share added between two checks (fake clock + 24 h) | Start checks both folders; the daily check after the share appears reports it once (flag, status line, log) and doesn't stop SRRVRR | FSL, CLK |
| T48-11 | P1 | U | `DataPath = ''` | `state\` and `logs\` created under SRRVRR's own folder | TH |
| T48-12 | P2, P6 | U | `DataPath` doesn't exist at start | Falls back to the own folder with reason `missing`; status line says where data goes now; the `DataPath` folder is **not** created (`Test-Path` still false afterwards) | TH |
| T48-13 | P2 | U | `DataPath` read-only at start (deny-write rule for the current user) | Falls back; reason `read-only`; `DataPath` left untouched | TH (read-only folder) |
| T48-14 | P2 | I | Start on a writable `DataPath`; make it read-only; write twice; make it writable again; write | First failed write switches to the fallback and is written there; one fallback notice; every later write (including after it's writable again) goes to the fallback; no day's log exists in both places after the switch | TH (read-only folder) |
| T48-72 | P2 | U | Review Focus 2: the data drive fills up (`IOException`, disk full) on a write | The same fallback and flag as a read-only folder, and the write lands in the fallback folder | TH |
| T48-73 | D6 | I | A thread writes to the shared state as fast as it can while `/stats` copies it, for 3 s | Every copy succeeds (found live after the #48 deploy: "Collection was modified") | TH |
| T48-15 | P7, X3 | U X | `Lock-TestDataPath` holds `state\srrvrr.lock`; resolve the data folder | Refuse (exit 3) with a message naming the folder | TH |
| T48-16 | P7 | U | Lock file left on disk by a crashed copy (exists, not held); a copy that stops cleanly | Start succeeds and takes the lock; after a clean stop the lock is released (the file opens exclusively) | TH |
| T48-17 | P7, X3 | K X | Test build B configured with the same `DataPath` as running test build A (stand-in for "pointed at the live data folder") | B exits 3 naming the folder; A keeps running and its history and logs are unchanged. Second case: A's data folder also made read-only for B (as an elevated live copy would): B still exits 3, not a fallback (OQ10) | NTB, TH |
| T48-18 | P8, SEC3 | U X | `Get-DataFolderAclPlan` (pure) from an ACL that grants Users write, Everyone read, the owner's account full control, inheritance on | Write removed for everyone but SYSTEM and Administrators; read access left as it was (the owner keeps read); inheritance off; SYSTEM and Administrators full control | - |
| T48-19 | P8 | E X | Runner, elevated: apply the plan to a temp `DataPath`; then a case where `Set-DataFolderAcl` throws (Mock) | ACL read back matches the plan on `state\` and `logs\`; on failure the reason is logged and start refuses with exit 3 | TH, Mock |
| T48-20 | P8 | U | Unelevated start | Permissions step skipped; console says so; `Set-DataFolderAcl` called 0 times | Mock |
| T48-21 | C1 | K | Test build started and stopped | Today's `srrvrr-*.log` holds the settings source, each startup step label in order, a "serving" line with the URL, then "stopped: requested (exit 0)" | NTB |

**Settings and exit codes**

| Id | Req | Lvl | Inputs | Expected | Asset |
|---|---|---|---|---|---|
| T48-22 | ST2 | U | `LogRetentionDays` 6, 7, 31, 366, 367, 31.5, `'31'`, `$null` | 7, 31, 366 accepted; the rest: one plain message naming the setting and its range, as `SrrSettingsException`; default 31 | FX config |
| T48-23 | ST3, ST4 | U | `MaintenanceMaxHours` 0.99, 1, 24, 24.01; `MaintenanceHours` 0.24, 0.25, equal to the maximum, the maximum + 0.01, with the maximum both default and set in the same file | Boundaries as the spec's table; defaults 2 and 8 | FX config |
| T48-24 | ST1 | U | `DataPath` relative (`data`), drive-relative (`X:data`), UNC, `\\?\` form, no drive letter (`\data`), a number; a full local path that exists; one that doesn't; one that's read-only | Relative, drive-relative, UNC, `\\?\`, no letter, non-string: settings error. The three full local paths: accepted (missing and read-only fall back at start, never a settings error) | FX config |
| T48-25 | ST5, X2 | K | Test build with each invalid config, a config that doesn't parse, and an old invalid one (`FirewallScope = 'Open'`) | Exit 2 (the old one was 1 before); one plain console line, no PowerShell error block; a "settings error" line in the own folder's `logs\`; last line "stopped: settings error (exit 2)" | NTB, FX config |
| T48-26 | ST6 | S | `SRRVRR.config.example.psd1` parsed, and `Get-SrrDefaultSettings` | Each new setting present, commented, with the same default as the code; `$retired` unchanged | - |
| T48-27 | X1-X5 | U | `Get-SrrExitCode` with: `SrrSettingsException`; `SrrRefusalException`; either one wrapped in a `RuntimeException`, a `MethodInvocationException` or an `ErrorRecord` from a nested call; a plain exception; `$null` | 2; 3; the inner type's code; 1; 1 | TH (C# classes) |
| T48-28 | C4 | U | `Format-StopLine` for requested, Ctrl+C, settings error, refusal, crash | `stopped: requested (exit 0)`, `stopped: Ctrl+C (exit 0)`, `stopped: settings error (exit 2)`, `stopped: refused: <why> (exit 3)`, `stopped: crash: <type> (exit 1)` | - |

**Network tracer and log lines**

| Id | Req | Lvl | Inputs | Expected | Asset |
|---|---|---|---|---|---|
| T48-29 | C3 | I | `ProcessNetTrace` source from `SRRVRR.ps1` compiled in an unelevated child process; `Start()` | Returns false; last error text "needs administrator" with its type; error count 0; alive flag false; `Drain()` empty | TH (child process) |
| T48-30 | C3 | E | Same, elevated on the runner; a download; `Drain()`; `Stop()` | `Start()` true; alive flag true; bytes counted for the child's process id; after `Stop()` the alive flag goes false and no `SRRVRRNet` session remains | TH |
| T48-31 | C3 | U | `Get-TracerLogEntry` with: no error; count 0 to 1; same count again; count 1 to 4; alive flag true to false; false again | Nothing; one entry with text and type; nothing; one entry noting 3 more; one entry "network tracer thread stopped"; nothing | - |
| T48-32 | C1 | U | `Format-LogLine` with a fixed time, level, source and a message containing a newline | Matches `^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}[+-]\d\d:\d\d (INFO|WARN|ERROR|FLAG) [a-z-]+: .+$`; the newline escaped so the entry stays one line (format pinned; OQ6) | CLK |

**Stop signal**

| Id | Req | Lvl | Inputs | Expected | Asset |
|---|---|---|---|---|---|
| T48-33 | S2, S3, SEC5 | U X | `New-StopEventSecurity -Elevated` and `-Elevated:$false` (pure) | Elevated: exactly SYSTEM (S-1-5-18) and Administrators (S-1-5-32-544), allowed to signal and change; no Everyone, Users or Authenticated Users. Unelevated: only the current user's SID. Inheritance off in both | - |
| T48-34 | S2, SEC5 | E X | Runner, elevated: `New-StopEvent` for a temp folder | `Global\SRRVRR-stop-<hash>` exists; owner and access rules read back as T48-33 | TH |
| T48-35 | S6, SEC5 | U X | `Test-StopEventTrusted` over owner and rule combinations: owner SYSTEM or Administrators with no one else allowed to signal; the same plus an Everyone signal rule; owner another user; unelevated, owner the current user, no one else; unelevated with an extra Users rule | Trusted; refused; refused; trusted; refused. A refusal is `SrrRefusalException` (exit 3) and logs the owner it found | - |
| T48-36 | S6, X3 | K X | `New-SquattedStopEvent` creates the test build's `Local\` name first with an Everyone rule; start the copy | Exit 3; the log says the stop event name is taken and by whom; after the squatter's handle closes, the copy starts normally | NTB, TH |
| T48-37 | S1 | U | `ConvertTo-StopPath` and `Get-StopEventName` with: one folder in different case; with and without a trailing `\`; through a mapped drive letter (fake mapping to a UNC path) and through that UNC path; an 8.3 short name and its long name (skipped when the test volume has no short names) | Equal names for each pair; the normalized path is upper case, long names, no trailing `\`, UNC for mapped drives; the name is `SRRVRR-stop-` plus the first 16 hex characters of the SHA-256 of that path (checked against a precomputed value for a fixed path); two different folders give different names | Mock |
| T48-38 | S5, S7, S8 | U | `Invoke-StopCommand` with mocked openers: `Global\` name exists and opens; only `Local\` exists; neither; `Global\` gives access denied | Opens with signal rights only (asserted on the mock); tries `Global\` first, then `Local\`; writes `state\stop-requested` (time and who asked) before signalling; "not running" when neither exists; on access denied relaunches itself elevated once (`Start-Process -Verb RunAs` mocked) | Mock, TH |
| T48-39 | S11, S12, T1 | U X | `Select-SRRVRRProcess -Folder` over the command line fixtures | Picks only processes whose `-File` argument resolves (by T48-37's rules, plus quotes, spaces, and a relative path against the process's working folder) to this folder's `SRRVRR.ps1`; never the caller's own id; never a `-Stop` process; an `SRRVRR.ps1` in another folder and a legacy `SRRVRR - test.ps1` in the same folder are not picked | FX cmdlines |
| T48-40 | S5, S11 | U | `Invoke-StopCommand` where the signal is sent but the copy doesn't exit within the timeout (2 s in the test) | After the timeout, `Stop-Process` is called only for the processes T48-39 picks; the result says it was forced | Mock |
| T48-41 | S1, S3 | I | Unelevated: a runspace waits on the folder's stop event; `Send-StopSignal` from another runspace; then from a different folder | Wakes within 1 s; the other folder's signal doesn't wake it | TH |
| T48-42 | S9 | U | Startup step helper with `Test-StopSignal` mocked to return true at step 3 of 9 | Steps 4 to 9 don't run; the stop path runs; "stopped: requested", exit 0 | Mock |
| T48-43 | S4 | U | `Invoke-GracefulStop` with fakes for the history and Maintenance savers (no-ops until #49 and #50), the log and the listener | Calls the savers, writes "stopped: requested (exit 0)", closes the listener, returns 0; a saver that throws is logged and the stop still returns 0 | Mock |

**Firewall and listener**

| Id | Req | Lvl | Inputs | Expected | Asset |
|---|---|---|---|---|---|
| T48-44 | SEC1, T4 | U | `Get-FirewallRulePlan -Copy live` for LocalSubnet, Allowlist, Blocklist | One `SRRVRR` allow rule (LocalSubnet or the addresses); Blocklist adds `SRRVRR (blocked)`; TCP inbound on the port; both in the live copy's rule group | - |
| T48-45 | T2, T4, T5 | U X | `-Copy test` (all scopes) and `-Copy live` removal lists | Test: `SRRVRR (test)` and `SRRVRR (test, blocked)` in the test group; it removes only rules in its own group, never the old `System Monitor` rules. Live: removes rules in the live group plus the old `System Monitor` rules | - |
| T48-46 | T3, T6 | U | Unelevated, both copies | Plan is "no rule" (`Sync-FirewallRule` called 0 times); listener prefix `http://localhost:<port>/` only; status line says only this machine can open the page | Mock |
| T48-47 | T2, T4 | E X | Runner: live rule `SRRVRR` (port A, live group) and a legacy `System Monitor` rule exist; run the test copy's sync on port B | `SRRVRR (test)` exists on port B in the test group; the `SRRVRR` and `System Monitor` rules are unchanged; everything removed in `AfterAll` | - |
| T48-48 | SEC1, T5 | E | Runner: live sync twice with Blocklist, with a legacy `System Monitor` rule present | One `SRRVRR` and one `SRRVRR (blocked)` after the second run; the legacy rule removed; remote addresses LocalSubnet or the listed private addresses | - |

**Test build tool**

| Id | Req | Lvl | Inputs | Expected | Asset |
|---|---|---|---|---|---|
| T48-49 | T1 | U X | `New-TestBuild.ps1` with a destination inside `-LiveFolder`; a non-empty destination; `-Force` on a folder without `TESTBUILD.txt`; a destination whose files would pass 259 characters; `-DataPath` equal to or inside `-LiveFolder` | Refuses each, writes nothing | TH |
| T48-50 | T1, T7 | I | `New-TestBuild.ps1 -Ref HEAD` into a temp folder, with and without `-DataPath` | Only runtime files (as T47-05) plus the test config, the test marker and `TESTBUILD.txt`; the config's `DataPath` is the given folder or empty; nothing read from any live folder | TH |

**Smoke on a test build** (each starts its own copy unelevated on a free port)

| Id | Req | Lvl | Inputs | Expected | Asset |
|---|---|---|---|---|---|
| T48-51 | T1, T3, T6, B5 | K | Start the copy from its own folder | `/stats` ready within 20 s (time logged); listening on `localhost` only (a request to the machine's own IPv4 address isn't answered); no `SRRVRR (test)` rule exists (read-only check) | NTB, TH |
| T48-52 | S4, S5, S8, X1, C4 | K | Run the copy's own `Stop SRRVRR.bat` (via `cmd /c`) | `state\stop-requested` written; the copy exits 0 within 10 s; last log line "stopped: requested (exit 0)"; the stopper exits 0 | NTB, TH |
| T48-53 | S1, S12, T1 | K X | Copies A and B in two folders; `-Stop` from A | A exits 0; B still answers `/stats`; B's folder has no `stop-requested`; then B stopped the same way | NTB, TH |
| T48-54 | S9 | K | Send the stop signal 3 s after starting the copy (during startup) | Exits 0 at the next step; "stopped: requested (exit 0)"; no crash line | NTB, TH |
| T48-55 | X4, C2 | K | Copy with `modules\Events.psm1` removed | Crash exit (not 0, 2 or 3; the `trap` gives 1); the log names the missing module file and the exception | NTB |
| T48-56 | C2, C4, X4 | K | Port taken first by an `HttpListener` on `http://localhost:<port>/` in the test process; start the copy on that port | Exit 1; one plain console line; the log holds the exception's type, message, script line number and stack, then "stopped: crash: ... (exit 1)" | NTB, TH |
| T48-57 | S10, X1 | K | Copy started in its own console, then Ctrl+C sent (`GenerateConsoleCtrlEvent` from a helper attached to that console) | Exit 0; last line "stopped: Ctrl+C (exit 0)"; history and Maintenance saved (once #49 and #50 exist) | NTB, TH |
| T48-58 | C4, X4 | K | `Stop-Process -Force` on a running copy | Exit code not 0, 2 or 3; no "stopped:" line for that run; no `stop-requested` marker | NTB |

**Crash log, worker watcher, cap**

| Id | Req | Lvl | Inputs | Expected | Asset |
|---|---|---|---|---|---|
| T48-59 | C2 | U | `Format-SrrException` with a nested exception from a script | Type, message, script name and line, `ScriptStackTrace`, and each inner exception's type and message | - |
| T48-60 | C5 | U | Same error 5 times in 59 s, then once at 60 s; two different errors interleaved; a stop with a pending repeat count | One line, then one line "(repeated 4 times)"; the two errors throttle separately; the pending count is written on stop | CLK |
| T48-61 | C6 | U X | Crash log with `-CapBytes 2048`: write past the cap; more INFO and ERROR lines; a FLAG line and the stopped line; clock past local midnight; write | Lines until the cap, then exactly one "daily size cap reached" line; later INFO/ERROR dropped; the FLAG line and the stopped line still written; the next day's file is written again; the cap counts bytes (a multi-byte message); the default is 20 MB | CLK, TH |
| T48-62 | C8 | U | `Test-WorkerHealth` with fake workers: Running; Failed with a reason and errors; Completed | Nothing; a log line with the reason and the worker's errors, the status line set, and the decision "exit with a crash code"; the same for Completed ("worker ended") | - |
| T48-63 | C8 | I | A real runspace whose loop function throws a terminating error after 2 ticks, watched by the main loop's watcher (checked once a second) | Within 2 s the watcher logs the failure and returns a crash exit code | TH |
| T48-64 | C1 | I | `Invoke-FastTick` with a reader that throws every time, 3 ticks; clock + 61 s; one more | Status line shows the error; one log line, then one with the repeat count (through the queue, drained by `Invoke-QueueDrain`) | FCR, CLK, TH |

**Drives card**

| Id | Req | Lvl | Inputs | Expected | Asset |
|---|---|---|---|---|---|
| T48-65 | P4 | U | `Select-DrivesToShow` with fixed drives, a removable drive holding `DataPath`, another removable drive, a data drive under 1 GB, `DataPath` on a folder mount point | Fixed drives of 1 GB or more as today; the removable data drive shown; the other removable not; the small data drive shown; the mount point's volume (from `Win32_Volume`) is the one marked | FX drives |
| T48-66 | P4 | U | Data drive health `Unknown`; data drive already fixed; data drive missing; on the fallback | Shown as "Unknown"; listed once; stays on the card as missing; while on the fallback, the fallback's drive is the one watched | FX drives |
| T48-71 | P4 | U | Review Focus 1: on the fallback, the configured data drive comes back | Both the configured drive and the fallback's are watched; the configured drive shows present again, not missing | - |

**Launcher contract, README text, performance and UAT**

| Id | Req | Lvl | Inputs | Expected | Asset |
|---|---|---|---|---|---|
| T48-67 | DEP3 | I | `tests\fakes\FakeLauncher.ps1` with stub scripts exiting 0, 2, 3, then 1 four times (fake clock); a stub that exits 1 within 60 s of a `stop-requested` marker; one 61 s after | No restart on 0, 2, 3; restarts on 1 up to 3 times in 10 minutes, then stops and logs it; the marker case is treated as requested (no restart, marker deleted); the 61 s case is a crash | CLK |
| T48-68 | DEP2 | S | `README.md` | The `-Stop` text says it stops only its own folder's copy; the test-copy text says to use the test folder's `Stop SRRVRR.bat`; closing the console window is a hard stop that can lose up to 5 minutes of history and the last log line | - |
| T48-69 | B1-B7 | P | Test build, 60 s; disk writes from the logs only | Within budgets; numbers in the PR | NTB, MS |
| T48-70 | B8, P2, P3, P4, P7, P8, S5, S6, T1-T3 | A | `docs\uat\48-running-safely.md` (the live data folder step also checks OQ10) | Force an error (port taken): in the log. Make the test data folder read-only (or remove a spare removable drive holding it): falls back, flag on the status line. The test folder's `Stop SRRVRR.bat` stops only the test copy, exit 0. Create the stop event's name first as an ordinary user: exit 3. Share a throwaway folder below the test data folder (owner, elevated): exit 3. Point a test build at the live data folder while the live copy runs: exit 3, live copy unaffected. The data drive on the drives card. An elevated test copy creates only the test rules, in their own group (owner checks in the firewall console) | UC |

### 6.3 #49 History

| Id | Req | Lvl | Inputs | Expected | Asset |
|---|---|---|---|---|---|
| T49-01 | H1 | U | Ring of 5 slots; append 7 readings | Copy holds the last 5, oldest first; the newest reading's time is the 7th's; default size is 900; the default lines are cpu, mem, gpu, rx, tx | CLK |
| T49-02 | H1 | U | Appends at t, t+1 s, then t+4 s (two ticks missed), then two in the same second | The missed seconds are `NaN` in the ring and `null` in JSON; two in one second: the later one wins, nothing shifts | CLK |
| T49-03 | H1 | I | Two runspaces: one appends 10,000 readings, the other takes copies in a loop | No exception; every copy is 900 long and in time order (the lock covers append and copy) | TH |
| T49-04 | H2 | U | Append a string, `$null`, a hashtable, `[double]::PositiveInfinity` | Stored as missing (`null` in JSON); only numbers ever reach the ring | - |
| T49-05 | H3 | U | `Register-HistoryLine 'test-line'`; register it again; append to an unregistered name | Saved, loaded and served like the built-in lines; the second register is a no-op; the unregistered append throws a clear error (caught by the sampler's try) | - |
| T49-06 | H1, D3 | U | `ConvertTo-HistoryJson` (the hand-built `StringBuilder` writer) for full rings with `NaN`, negative zero, very small and very large values | Parses with `ConvertFrom-Json`; numbers round-trip to 3 significant decimals (pinned); `NaN` written as `null`; invariant culture (`.` decimal point even under a culture that uses `,`: run with `de-DE` set for the thread) | - |
| T49-07 | H1, B3 | U | Same writer, 5 lines x 900 values, timed 20 times | Median under 20 ms on the CI runner (informational), and much faster than `ConvertTo-Json` on the same data (both printed); output under 150 KB | - |
| T49-08 | H4 | U | `Save-History` to `TestDrive:\state` with no existing file; then with one | Writes `history.json.tmp`, then moves it (first time) or `[IO.File]::Replace`s it (later); no `.tmp` left; content has `version: 1`, `newestMs`, `stepMs: 1000` and the arrays | TH |
| T49-09 | H4 | U X | A partial `history.json.tmp` left next to a good `history.json` (a crash mid-write) | Load uses `history.json`; the next save overwrites the `.tmp` and succeeds | TH, FX history |
| T49-10 | H8 | U | Save into a read-only `state\`; save while `history.json` is locked by another handle | Returns a failure result, doesn't throw; status line text set; one error-log line through the queue; the next save is tried again on schedule | TH, Mock |
| T49-11 | H6 | U | `good.json` with `newestMs` 5 minutes before now; `edge.json` at 14 min 59 s; `stale.json` at 15 min 1 s | First two loaded; the gap from `newestMs` to now is missing values at the end of each ring (300 and 899 of them); the stale one is ignored (history starts empty) and left as it is, not renamed | FX history, CLK |
| T49-12 | H6 | U | `newestMs` in the future (clock stepped back) by 1 minute and by 1 hour | Pinned: treated as unusable and ignored, not renamed (OQ7) | FX history, CLK |
| T49-13 | H7 | U X | `damaged.json`; `wrong-types.json`; an existing older `history.json.bad` | Renamed to `history.json.bad` (the older `.bad` replaced); history starts empty; one error-log line; no crash | FX history |
| T49-14 | H5, H7, Q6 | U | `unknown-version.json` (`version: 99`) | Renamed to `.bad`, history starts empty, no crash; the next save writes a version 1 file (this is also the rollback case: an older SRRVRR meeting a newer file) | FX history |
| T49-15 | H7, P9 | U X | Generated file of 2 MB + 1 byte; one of exactly 2 MB that's valid | The first renamed `.bad` without being read past 2 MB (the reader is mocked to count bytes read); the second loaded | TH |
| T49-16 | H1 | U | File with an extra unknown line and a missing registered line; lines of the wrong length | The unknown line dropped; the missing line starts empty; wrong-length arrays: the newest values kept, aligned to `newestMs` (pinned) | FX history |
| T49-17 | H4 | U | `Test-HistorySaveDue` on a fake clock over 16 minutes; `Invoke-GracefulStop` with a real history saver | Due at 5, 10 and 15 minutes; the stop path writes the file | CLK, TH |
| T49-18 | H1, F8 | I | `Invoke-FastTick` with the fake reader, 3 ticks | Each tick appends cpu, mem (percent of total, pinned), gpu, rx and tx to the rings; the save itself runs in the slow sampler (`Invoke-SlowTick` calls `Save-History`; the fast tick never does) | FCR, TH |
| T49-19 | D3 | I | GET `/history` from the test server with full rings | 200, JSON with `version`, `newestMs`, `stepMs` and every registered line at 900 entries; `Content-Type: application/json; charset=utf-8`; `Cache-Control: no-store`; under 150 KB | TH |
| T49-20 | D3, B10 | I | GET `/history` 50 times | p95 under 50 ms (the reader takes a copy under the lock and serializes the copy) | TH |
| T49-21 | W3, W5, SEC2 | I X | `POST /history`; GET with a bad `Host` | 405; 421 | TH |
| T49-22 | D6, DEP1 | I | `/stats` shape after #49 | Still contains every v0.6.0 path (T47-17 re-run; it's in every PR's suite) | FX stats |
| T49-23 | H4, H6 | K | Test build runs 2 minutes; `-Stop`; wait 30 s; start again | `history.json` exists after the stop; after the restart `/history` holds the earlier readings, then about 30 s of `null`, then new readings | NTB, TH |
| T49-24 | H7 | K | Overwrite the test build's `history.json` with damaged data while it's stopped; start | `history.json.bad` exists; the copy serves; one error-log line | NTB |
| T49-25 | H2, SEC3 | I X | Fast and slow ticks with canary process and player names in the fixtures; save | `Assert-NoCanary` over `state\` finds nothing; `history.json` holds only the format fields, line names and numbers (checked with a regex over the file) | FPS, TH |
| T49-26 | D3 | J | `fillFromHistory(json)` | Fills the page's buffers; `null`s stay as gaps; on a reconnect (a failed poll, then a good one) the page asks for `/history` again (`shouldRefetchHistory`) | tests\js |
| T49-27 | G1 | J | `rangeFromStorage` with nothing stored, `'60'`, `'900'`, `'abc'`, and storage that throws | 60, 60, 900, 60, 60; choosing a range writes it to storage | tests\js |
| T49-28 | G1, H6 | J | `visibleSlice(buffer, range)` and `toSegments(values)` | 60 s shows the last 60 values; 15 min shows 900; missing values split the line into segments (a gap, not a drop to zero) | tests\js |
| T49-29 | B1-B7, B10 | P | Test build, 60 s, with `/history` requested every 2 s by a second thread | Within budgets; `/stats` p95 still 30 ms while `/history` is requested; disk writes about 29 MB a day scaled | NTB, MS |
| T49-30 | B8, H4, H6, H7, G1 | A | `docs\uat\49-history.md` | Two browsers on the server (or two PCs with an elevated test copy, OQ3) refresh: the graphs start full. Restart: history comes back with a gap. Damage the state file: it's renamed `.bad`. The 15-minute button, remembered per browser | UC |

### 6.4 #50 Events, logs, Maintenance and the Flagged list

**Ids, the queue and the store**

| Id | Req | Lvl | Inputs | Expected | Asset |
|---|---|---|---|---|---|
| T50-01 | E3 | U | `New-EventId` on a fake clock: two events in the same millisecond; ten in a row with the clock frozen; the clock stepped back 1 hour; a restart seeded with the last id from today's log that's ahead of the clock | Strictly increasing every time: the id is the larger of now in ms and last id + 1; after the step back, ids keep counting from the last one | CLK |
| T50-02 | E2 | U | `New-SrrEvent` with each severity, a bad severity, missing key | Fields id, time, type, severity (`info`, `warn`, `flag`), key, data, `maintenance`; a bad severity or a missing key throws | CLK |
| T50-03 | E4 | U | Same key at 0, 5, 9:59 and 10:00 minutes; two keys interleaved | Kept at 0 and 10:00 (pinned: measured from the last kept one), the others suppressed (not stored, not logged); keys independent | CLK |
| T50-04 | E5, E10 | U | 205 events through `Invoke-QueueDrain`; hold a reference to the published array, then drain one more | 200 kept, the oldest 5 gone; the held array is unchanged (a new array is published each drain, never changed in place) | CLK |
| T50-05 | E9, E10 | I | Three runspaces add 300 events each to the shared queue while the main runspace drains and serializes the published array with `ConvertTo-Json` in a loop | No "collection was modified" or other exception; 900 events logged (capacity raised for the test), ids unique and increasing in file order; each daily file has one writer (no interleaved partial lines) | TH |
| T50-06 | E9 | S | Module and script ASTs | Only `Invoke-QueueDrain` (and the writers it calls) opens log files for writing; samplers and `Web.psm1` call `Add-SrrQueueItem` only | TH (AST) |

**Detection: the starting set of events**

| Id | Req | Lvl | Inputs | Expected | Asset |
|---|---|---|---|---|---|
| T50-07 | E7a, E8 | U | Valheim activity 1 player, then 2 with names (canaries); then 1 | `player-join` and `player-leave`, info, banner yes, logged no; names in the in-memory data only | FX activity |
| T50-08 | E7a | U | Plex items: none; one new key; the same key paused and resumed; first observation already with a stream | One `plex-stream` info event for the new key; nothing for pause / resume; nothing on the first observation (no replay) | FX activity |
| T50-09 | E7b | U | Processes rows: Valheim online to offline to online; the same for Plex | warn events for offline and back, banner yes, logged yes | FX activity |
| T50-10 | E7b | U | Valheim query answering, then error, then answering; Plex "didn't answer" | warn "status query stopped answering" logged; recovery logged as "back" (pinned) | FX activity |
| T50-11 | E7c | U | `restartPending` false to true, true to true | One info event, banner no, logged yes; nothing for true to true | - |
| T50-12 | E7d | U | Drive health Healthy to Warning; Unknown to Unknown; a new drive appearing; the data drive going missing | flag event, banner, logged for the change and for the data drive missing; nothing for Unknown to Unknown or a new drive (pinned) | FX drives |
| T50-13 | E7e | U | Fallback result from #48; the daily share check finding a new share | flag events "data folder fell back" and "share appeared on the data folder", banner and logged | FSL |
| T50-14 | E7f, E7g | U | History save failure result; a sampler error; a worker stopped | warn "history save failed" with banner; warn sampler error and "background worker stopped" with no banner (status line), all logged | - |
| T50-15 | E7h | U | Maintenance on and off; started; stopped with each reason | info, no banner, logged, with the reason | - |
| T50-16 | E7 | U | Data-driven: the spec's table (event, severity, banner, logged) copied into the test | Every event type the module defines appears in the table and matches it; no type is missing from the module | - |
| T50-17 | E1 | I | Test server with fake samplers moving through the activity fixtures and no client connected | Events appear in today's `events-*.jsonl` without any request | FX activity, TH |

**Event log, index, cleanup and cap**

| Id | Req | Lvl | Inputs | Expected | Asset |
|---|---|---|---|---|---|
| T50-18 | L1 | U | Write events either side of local midnight (fake clock), including across a daylight-saving change | Files `events-YYYY-MM-DD.jsonl` by local date; one JSON object per line; UTF-8 without a BOM; `Read-JsonLines` reads every line back | CLK, TH |
| T50-19 | E8, SEC3 | U X | Join, leave and stream events whose in-memory data holds canary player, user, device and title names | Logged lines hold counts only; `Assert-NoCanary` over `logs\` finds nothing | FX activity, TH |
| T50-20 | D4, D7 | U | `Initialize-EventIndex` from `events-good.jsonl` plus `events-bad-lines.jsonl` over three days; then new events written | Index holds every good logged event; bad and cut-off lines skipped and counted in one log line; new events are appended to the index as they're written | FX events |
| T50-21 | D7 | U | `Get-IndexedEvents -Days 31` with the file reader mocked | Answered from memory; the file reader is called 0 times per request | Mock |
| T50-22 | L2, C7 | U X | `Remove-OldLogs` over the `names.txt` set with `LogRetentionDays 31` (fake clock) | Deletes only regular files directly in the active `logs\` whose names match `^(events|srrvrr)-\d{4}-\d{2}-\d{2}\.(jsonl|log)$` and whose name date is older than retention; keeps look-alikes, other files, subfolders, and a junction and a symbolic link with matching old names (their targets untouched); age from the name, not the file time (a matching file with a new modified time and an old name is deleted) | CLK, FX logs, TH (junction) |
| T50-23 | L2 | U X | `LogRetentionDays 7` with files for the last 10 days; then the 7-day floor with retention 7 at its edge | The newest 7 days of files are never deleted; boundary pinned (the file dated exactly retention days ago is deleted; OQ5) | CLK |
| T50-24 | L2 | U X | Clock earlier than the newest file's date; clock more than `LogRetentionDays` past the newest file's date | Cleanup skipped in both cases with one error-log line; nothing deleted | CLK |
| T50-25 | L2 | U | `Test-CleanupDue` right after startup, 23 h later, 24 h later; a read-only old file | Due, not due, due; the read-only file is logged and skipped, cleanup goes on | CLK |
| T50-26 | C6, L1 | U X | Event log with `-CapBytes 2048`: info and warn events past the cap, then a flag event | One "daily size cap reached" line; info and warn dropped from the file (still in memory and on `/stats`); the flag event still written | CLK |

**Maintenance**

| Id | Req | Lvl | Inputs | Expected | Asset |
|---|---|---|---|---|---|
| T50-27 | M2 | U | Turn on at t with `MaintenanceHours 2`; read the state at t + 1:59:59 and t + 2:00:00 | `untilMs` = t + 2 h; on, then off; turning off by expiry logs "maintenance off (expired)" | CLK |
| T50-28 | M3 | U | Events raised while on | Logged and published with `"maintenance": true`; detection unchanged | CLK |
| T50-29 | M5 | U | Save and load `maintenance.json`: on with a future end; `expired.json`; `damaged.json`; `unknown-version.json`; a 4 KB + 1 byte file | On restored with the same `untilMs`; off; off with an error line (pinned: renamed `.bad`, OQ8); off; off without reading past 4 KB | FX maintenance, CLK |
| T50-30 | M11, P9 | U X | `far-future.json` with `untilMs` a year ahead, `MaintenanceMaxHours 8` | Held to now + 8 h | FX maintenance, CLK |
| T50-31 | M9 | U | `POST /maintenance` bodies `{"on":true}`, `{"on":false}`, `{"on":"yes"}`, `{"on":1}`, `{}`, `{"on":true,"hours":24}`, not JSON, empty | First two accepted; the type mismatches, missing field and bad JSON get 400; extra fields ignored (duration always `MaintenanceHours`) | - |
| T50-32 | M6 | U | A change from remote address A with `X-Forwarded-For: B` | Logged with A only (the header is ignored); data has on/off and `untilMs` | - |
| T50-33 | M10 | U X | Changes from one address at 0, 5, 10 s; from a second address at 5 s; 61 changes from one address in a day (10 s apart, fake clock); the day rolls over | 0 s ok, 5 s 429, 10 s ok; the second address ok at 5 s; the 61st gets 429; refused ones are counted in one log line, not logged one by one; the next day is allowed again | CLK |
| T50-34 | D5, M1 | I | Valid POST from client 1; GET `/stats` from client 2 | 200 with `{on, untilMs}`; client 2 sees `maintenance.on` and the same `untilMs` | TH |
| T50-35 | M8 | I | POST with a correct `Origin` from `127.0.0.1` with no other identity | Accepted (any device that can open the page may tick it, by design); logged with its address | TH |

**The request guard and the web limits**

| Id | Req | Lvl | Inputs | Expected | Asset |
|---|---|---|---|---|---|
| T50-36 | M7, W6, SEC2 | U X | `Test-MaintenanceRequest` table, `Host` allowed in every case: (a) no `X-SRRVRR`; (b) `X-SRRVRR: 0`, `2`, `yes`; (c) `Content-Type` missing or `text/plain`; (d) `Origin` with an allowed host and port; (e) another host; (f) an allowed host on another port; (g) `https://` with an allowed host; (h) `Origin: null`; (i) no `Origin` but a matching `Referer`; (j) neither; (k) upper-case host; (l) `[::1]`; (m) `application/json; charset=utf-8` | Only (d), (k), (l) and (m) accepted; every other case 403 (no `Referer` fallback: a request with no `Origin` is refused) | - |
| T50-37 | W5, M7 | I X | DNS rebinding: `POST /maintenance` with `Host: evil.example:<port>`, `Origin: http://evil.example:<port>` and the header | 421 before the guard runs; state unchanged | TH |
| T50-38 | W3, SEC2 | I X | `GET`, `PUT`, `DELETE`, `OPTIONS` on `/maintenance`; `POST` on `/stats`, `/history`, `/events`, `/` | 405; no `Access-Control-*` header; Maintenance state and every store unchanged (compared before and after) | TH |
| T50-39 | D1 | I | GET `/stats` with no `since`, with 30 events in memory | `events: []` and `lastEventId` = the newest id; `maintenance` `{on, untilMs}`; every v0.6.0 path plus `tickMs` | TH, FX stats |
| T50-40 | D2 | I | GET `/stats?since=<id>` with 120 events in memory: a recent id (10 newer); an old id (100 newer); the newest id; an unknown id; a future id; `since=abc`; `since=` | 10 events oldest first, no `eventsTruncated`; 50 events (the oldest 50 after the id, pinned), `eventsTruncated: true`; empty; newest 50; newest 50; `abc` and empty treated as unknown (newest 50, pinned) | TH |
| T50-41 | D4 | I | GET `/events?days=n` for 1, 31 (`LogRetentionDays` 31), 32, 0, -1, 1.5, `abc`, missing; with `LogRetentionDays 60`, `days=60` | 200 for 1 and 31 (newest first; 1 returns today's only); 400 for the rest including missing (pinned: missing is 400, OQ9); 200 for 60 when retention is 60 | TH, FX events |
| T50-42 | D4 | I X | Index with 5,000 events over 31 days | `/events?days=31` returns the newest 1,000, newest first | TH |
| T50-43 | B10, B3 | I | `/events?days=31` with 5,000 indexed events, 50 times; `/stats` p95 measured from a second thread meanwhile | `/events` p95 under 50 ms; `/stats` p95 under 30 ms (informational on CI, budget on the owner's machine) | TH |
| T50-44 | D4, SEC3 | I | `/events` after the canary run of T50-19 | No canary word in the response | TH |

**The page**

| Id | Req | Lvl | Inputs | Expected | Asset |
|---|---|---|---|---|---|
| T50-45 | E6 | J | First `/stats` response (`events: []`, `lastEventId: 500`) | `since` becomes 500; no banner; the next request is `/stats?since=500` | tests\js |
| T50-46 | E6, N1 | J | Following responses with events 501 to 503 (one banner type, one status-line-only type, one flag), then the same events again, then `eventsTruncated: true` | Banners for the banner types only, once each; `since` moves to the newest id seen; duplicates ignored; a truncated response still advances `since` (pinned: shows a "more events" note) | tests\js |
| T50-47 | M3, M4 | J | `maintenance: {on: true, untilMs}` with new events | No banner, no ding; text "Maintenance until HH:MM" in the browser's own time zone (tested under two time zones by passing the formatter's zone) | tests\js |
| T50-48 | N1 | J | Valheim and Plex event data for the scenarios the old `watchValheim` / `watchPlex` handled (joins with names, n players, leaves, new stream transcoding on the GPU, direct play) | Banner titles and lines equal the v0.6.0 page's output for the same scenarios (golden values captured from the old functions) | tests\js |
| T50-49 | N2 | J | Sound toggle on, off, storage that throws | Same storage key as v0.6.0; per browser; a storage error leaves sound off without breaking the page | tests\js |
| T50-50 | FL1 | J | `/events` responses: 20 events; none; a 400 | Listed newest first with severity and time; "nothing flagged in the last 31 days"; a plain error line | tests\js |
| T50-51 | N1 | S | `web\app.js` text | No page-side comparison of activity left (`lastValheim`, `plexKeys` and their comparisons are gone) | - |

**Smoke, performance and UAT**

| Id | Req | Lvl | Inputs | Expected | Asset |
|---|---|---|---|---|---|
| T50-52 | M1, M5 | K | Test build: POST Maintenance on (correct `Host`, `Origin`, header and content type); restart the copy | Still on after the restart, same `untilMs` | NTB, TH |
| T50-53 | E7h, C4 | K | Start and `-Stop` a test build | Today's events log has "started" and "stopped" (reason: requested); the crash log's last line is "stopped: requested (exit 0)" | NTB |
| T50-54 | B1-B7, B10 | P | Test build, 60 s, 200 events in memory, `/events` and `/history` requested by a second thread | Within budgets; `/stats` size grows only by the events it carries (at most 50) | NTB, MS |
| T50-55 | B8, M1-M6, FL1, N1, N2 | A | `docs\uat\50-events.md` | Tick Maintenance in one browser: the other shows it, no banners or dings, events logged with `"maintenance": true`, the log has the address. Valheim / Plex banners come from the server (open a page after an event: no replay). The Flagged list shows the last 31 days. Sound toggle per browser | UC |
| T50-56 | B2 | P | 60-minute soak of the release candidate and of the previous release, same machine, same way (`Measure-SRRVRR.ps1 -SoakMinutes 60`) | Private bytes after 60 minutes within 25 MB of the previous release's; recorded in `tools\budgets.psd1` for the next release | NTB, MS |

### 6.5 #51 README: running SRRVRR at boot

README tests are drift tests: they compare what the README says with what the code and the archive actually do,
so the text can't quietly go stale.

| Id | Req | Lvl | Inputs | Expected | Asset |
|---|---|---|---|---|---|
| T51-01 | X1-X4, DEP3 | S | The exit code table in the README's "running at boot" section, parsed; `Get-SrrExitCode`'s map | Same codes and the same "start it again?" answers; the restart advice says crash codes only, up to 3 times in 10 minutes | - |
| T51-02 | DEP2, DEP3 | S | README's update steps; `git archive HEAD` file list | Says to replace the code folders; every runtime folder and top-level file the archive holds is named (and nothing it doesn't) | - |
| T51-03 | DEP3, S8 | S | README | Describes `-Stop` / `Stop SRRVRR.bat` as the stop for launchers, the 10-second wait, and the `state\stop-requested` marker with its 60-second rule | - |
| T51-04 | DEP3, SEC4 | S | README | Says a hash-checking launcher must cover `modules\`, `web\` and the temperature library's DLLs as well as `SRRVRR.ps1`; that the launcher's release must be installed first; that the files load because of `-ExecutionPolicy Bypass` (the downloaded mark) | - |
| T51-05 | P5, P8 | S | README | Permissions text: elevated SRRVRR restricts writing `state\` and `logs\` to SYSTEM and Administrators; owners keep read | - |
| T51-06 | ST6 | S | README's settings section and `Get-SrrDefaultSettings` | Each new setting named with the same default and range as the code | - |
| T51-07 | Q4 | S X | `tools\Test-NoPrivateInfo.ps1` over `README.md`, `CHANGELOG.md`, `docs\` | Clean: no addresses, share names, drive paths or deny-list words | - |
| T51-08 | Q4 | S | Relative links and anchors in `README.md` and `docs\*.md` | Every link resolves to a file in the repo and every `#anchor` to a heading | - |
| T51-09 | Q4, Q5 | S | `CHANGELOG.md` | `[Unreleased]` has an entry for each of #47 to #51 before the release PR; the release PR moves them under `0.7.0` and the README version matches | - |
| T51-10 | B8, DEP3 | A | `docs\uat\51-readme.md` | The owner follows the README's boot steps on a test build with the boot launcher's test setup: start at boot, a crash restarts it, `-Stop` stops it without a restart, a settings error doesn't loop | UC |

## 7. Traceability

Every requirement in the spec (as revised 2026-10-29), by section, with its tests. `Traceability.Tests.ps1`
(T47-33) parses this table: every id in the last column must exist, and every test id in section 6 must appear here
at least once. "UAT only" marks requirements with no automated test, with the reason.

| Req | Spec section | Requirement (short) | Tests |
|---|---|---|---|
| B1 | Budgets | SRRVRR's own CPU at most 1% of the machine over 60 s | T47-28, T48-69, T49-29, T50-54 |
| B2 | Budgets | Private bytes after 60 min within 25 MB of the previous release | T50-56 (soak before the release; the per-PR runs record the 60 s figure) |
| B3 | Budgets | `/stats` p95 30 ms, also while `/history` and `/events` are requested | T47-28, T49-07, T49-29, T50-43, T50-54 |
| B4 | Budgets | Page load 150 ms | T47-28 |
| B5 | Budgets | Startup to serving 20 s | T47-28, T48-51 |
| B6 | Budgets | Tick median within 10% (or 5 ms) of PR 1's | T47-16, T47-28, T48-69, T49-29, T50-54 |
| B7 | Budgets | Disk writes up to 100 MB a day | T48-69, T49-29, T50-54 |
| B8 | Budgets | UAT about 15 minutes per PR | UAT only (a duration, timed by the owner): T47-35, T48-70, T49-30, T50-55, T51-10 |
| B9 | Budgets | `tickMs` in `/stats`; `tools\Measure-SRRVRR.ps1`, read-only | T47-16, T47-26, T47-27 |
| B10 | Budgets | `/history` and `/events` 50 ms each | T49-20, T50-43 |
| B11 | Budgets | Slow new work after serving; share list via CIM | T48-10, T48-51 (plus a `Static.Tests.ps1` check that no module calls `Get-SmbShare`, part of T50-06's AST pass) |
| F1 | 1 | The files and modules in the spec's table | T47-01, T47-07, T47-09, T47-11 to T47-15, T47-19, T47-31 |
| F2 | 1 | Same entry path and command line | T47-04, T47-30 |
| F3 | 1 | Page read from disk on every request | T47-20, T47-21 |
| F4 | 1 | `.ps1` / `.psm1` pure ASCII; `web\` may be UTF-8 | T47-02, T47-03 |
| F5 | 1 | Modules by full path at the top of each runspace; never by name; no `PSModulePath` | T47-08, T47-10 |
| F6 | 1 | `export-ignore` for tests, .github, docs, tools, .gitattributes, .gitignore | T47-05 |
| F7 | 1 | `.gitignore` adds `state/`, `logs/` | T47-06 |
| F8 | 1 | Work over about 50 ms in the slow sampler | T47-14, T49-18 (and review) |
| F9 | 1 | Downloaded files load because of `-ExecutionPolicy Bypass`; release notes say so | T47-40, T51-04 |
| F10 | 1, 7 | `tools\Invoke-Checks.ps1`, one script locally and in CI | T47-25 |
| W1 | 1, 8 | Fixed static path table, `img` name pattern, fixed types, `nosniff` | T47-20, T47-22 |
| W2 | 1 | Anything else 404 | T47-23 |
| W3 | 1 | GET only (plus `POST /maintenance`), else 405; no `Access-Control-*` header | T47-36, T49-21, T50-38 |
| W4 | 1 | Missing or unreadable `web\` file: 500 and an error-log line | T47-37 |
| W5 | 8 | `Host` must be the server's own name or address on the port, else 421 | T47-38, T47-39, T49-21, T50-37 |
| W6 | 8 | `POST /maintenance` needs `X-SRRVRR: 1`, JSON content type and an allowed `Origin`; no `Origin` refused | T50-36 |
| H1 | 2 | One reading a second, 900 per line, `double[]` rings with a lock, hand-built JSON | T49-01, T49-02, T49-03, T49-06, T49-16, T49-18 |
| H2 | 2 | Numbers only, never names | T49-04, T49-25 |
| H3 | 2 | Later features register lines by name | T49-05 |
| H4 | 2 | Saved every 5 min and on a clean stop, tmp then swap | T49-08, T49-09, T49-17, T49-23 |
| H5 | 2 | Format version, newest time, step in the file | T49-08, T49-14 |
| H6 | 2 | Used at start if the newest reading is under 15 min old; missing seconds are `null` | T49-11, T49-12, T49-23, T49-28 |
| H7 | 2 | Over 2 MB, damaged or unknown version: renamed `.bad`, history empty, never a crash | T49-13, T49-14, T49-15, T49-24 |
| H8 | 2 | A failed save: status line and error log, never fatal | T49-10 |
| D1 | 2 | `/stats` adds `tickMs`, `maintenance {on, untilMs}`, `lastEventId`, `events: []` | T47-16, T47-17, T50-39 |
| D2 | 2 | `?since=`: up to 50 newer, oldest first, `eventsTruncated`; unknown or future id gives the newest 50 | T50-40 |
| D3 | 2 | `/history`: every line's last 15 minutes | T49-19, T49-26 |
| D4 | 2 | `/events?days=n`: n from 1 to `LogRetentionDays`, else 400; newest 1,000, newest first | T50-20, T50-41, T50-42 |
| D5 | 2 | `POST /maintenance` returns the new state | T50-34 |
| D6 | 2 | `/stats` keeps every v0.6.0 field | T47-17, T47-18, T48-73, T49-22 |
| D7 | 2 | `/events` from an in-memory index, never files per request | T50-20, T50-21 |
| G1 | 2 | Graph buttons 60 s (default) and 15 min, remembered per browser | T49-27, T49-28 |
| P1 | 3 | `DataPath` default is SRRVRR's own folder; `state\`, `logs\` created inside it | T48-11 |
| P2 | 3 | Fallback when missing, read-only, or a later write fails; flag; stays until restart | T48-12, T48-13, T48-14, T48-72, T50-13 |
| P3 | 3 | Refuse (exit 3) for a share equal, above or below; junctions; whole names; special shares only ignored; network paths and mapped drives; unreadable list | T48-01 to T48-10 |
| P4 | 3 | Drives card watches the data drive (removable, mount points, under 1 GB, missing, fallback) | T48-65, T48-66 , T48-71 |
| P5 | 3 | Owner keeps read access; permissions explained | T48-18, T51-05 |
| P6 | 3 | `DataPath` itself is never created | T48-12 |
| P7 | 3 | `state\srrvrr.lock`: a second copy refuses (exit 3) | T48-15, T48-16, T48-17 |
| P8 | 3 | Elevated: only SYSTEM and Administrators can write, inheritance off, else exit 3; unelevated skips | T48-18, T48-19, T48-20 |
| P9 | 3 | Read caps: `history.json` 2 MB, `maintenance.json` 4 KB; Maintenance end held to the maximum | T49-15, T50-29, T50-30 |
| P10 | 3 | Share check at start on both folders and daily; a new share raises a flag | T48-10, T50-13 |
| E1 | 4 | Events decided on the server, without a page open | T50-17 |
| E2 | 4 | Event fields and severities | T50-02 |
| E3 | 4 | Ids: larger of now (ms) and last + 1 | T50-01 |
| E4 | 4 | Repeats of a key within 10 min suppressed | T50-03 |
| E5 | 4 | Last 200 in memory | T50-04 |
| E6 | 4 | Banners only for new events; no replay | T50-45, T50-46 |
| E7 | 4 | The starting set (table): severity, banner, logged | T50-16; a: T50-07, T50-08; b: T50-09, T50-10; c: T50-11; d: T50-12; e: T50-13; f, g: T50-14; h: T50-15, T50-53 |
| E8 | 4 | Names, users, devices and titles in memory only; logs get counts | T50-07, T50-19 |
| E9 | 4 | One writer: a shared queue drained by the main loop | T48-64, T50-05, T50-06 |
| E10 | 4 | The published event array is never changed in place | T50-04, T50-05 |
| L1 | 4 | `events-YYYY-MM-DD.jsonl` by local date, one object per line | T50-18, T50-26 |
| L2 | 4 | Cleanup: after start and daily; regular files only, exact pattern, name date, 7-day floor, skipped on a bad clock | T50-22, T50-23, T50-24, T50-25 |
| C1 | 4 | Crash log content: steps, settings problems, sampler errors, worker failures | T48-21, T48-32, T48-64 |
| C2 | 4 | The `trap` writes type, message, line and stack | T48-55, T48-56, T48-59 |
| C3 | 4 | Tracer keeps last error, type, count, alive flag; the fast sampler logs changes | T48-29, T48-30, T48-31 |
| C4 | 4 | Last line says why it stopped, with the code | T48-28, T48-52, T48-56, T48-58, T50-53 |
| C5 | 4 | Same error at most once a minute, with a count | T48-60 |
| C6 | 4 | 20 MB daily cap on both logs; flags and the stopped line still written | T48-61, T50-26 |
| C7 | 4 | Crash log retention matches the event log | T50-22 |
| C8 | 4 | Worker watcher: a failed or ended worker is logged and SRRVRR exits with a crash code | T48-62, T48-63 |
| N1 | 4 | Valheim and Plex banners from server events | T50-46, T50-48, T50-51 |
| N2 | 4 | Sound stays per browser | T50-49 |
| M1 | 4 | Maintenance kept on the server, for every browser | T50-34, T50-52 |
| M2 | 4 | Lasts `MaintenanceHours`, switches itself off | T50-27 |
| M3 | 4 | While on: no banners or dings; events logged with `"maintenance": true` | T50-28, T50-47 |
| M4 | 4 | "Maintenance until HH:MM" from `untilMs`, in the browser's time | T50-47 |
| M5 | 4 | Saved to `state\maintenance.json`, survives a restart | T50-29, T50-52 |
| M6 | 4 | Each change logged with the requesting address | T50-32 |
| M7 | 4, 8 | The request guard; no preflight permission | T50-36, T50-37 |
| M8 | 4 | Any device that can open the page may tick it (accepted risk) | T50-35 (behavior); the risk itself is the owner's call, not testable |
| M9 | 4 | Body `{"on": true}` or `{"on": false}` | T50-31 |
| M10 | 4 | Rate limit: 1 per address per 10 s, 60 a day, else 429, counted not logged | T50-33 |
| M11 | 3, 4 | End time read from the file held to `MaintenanceMaxHours` from now | T50-30 |
| FL1 | 4 | Flagged list: logged events of the last 31 days, newest first | T50-50, T50-55 |
| S1 | 5 | Named event per folder: `SRRVRR-stop-` + 16 hex of SHA-256 of the normalized path | T48-37, T48-41, T48-53 |
| S2 | 5 | Elevated: `Global\`, only SYSTEM and Administrators | T48-33, T48-34 |
| S3 | 5 | Unelevated: `Local\`, only the current user | T48-33, T48-41 |
| S4 | 5 | On the signal: save, log "stopped: requested", close, exit 0 | T48-43, T48-52 |
| S5 | 5 | `-Stop` / `Stop SRRVRR.bat` signal, wait about 10 s, then force | T48-38, T48-40, T48-52 |
| S6 | 5 | A taken name (wrong owner or permissions) refuses with exit 3 | T48-35, T48-36 |
| S7 | 5 | Stopper tries `Global\` then `Local\`, signal rights only; relaunches elevated on access denied | T48-38 |
| S8 | 5 | Stopper writes `state\stop-requested` first | T48-38, T48-52, T51-03 |
| S9 | 5 | Stop checked between startup steps | T48-42, T48-54 |
| S10 | 5 | Ctrl+C: clean path, "stopped: Ctrl+C", exit 0 | T48-57 |
| S11 | 5 | Forced stop matches only a process whose `-File` resolves to this folder's script | T48-39, T48-40 |
| S12 | 5 | `-Stop` stops only its own folder's copy | T48-39, T48-53 |
| S13 | 5 | Closing the console window is a hard stop; the README says so | T48-68 (text only; the loss itself isn't worth automating) |
| X1 | 5 | Exit 0: clean stop or Ctrl+C | T48-27, T48-52, T48-57 |
| X2 | 5 | Exit 2: settings error | T48-25, T48-27 |
| X3 | 5 | Exit 3: share, permissions, lock, taken stop name | T48-09, T48-15, T48-17, T48-19, T48-36 |
| X4 | 5 | Anything else: crash | T48-55, T48-56, T48-58 |
| X5 | 5 | Codes from two small C# exception classes, mapped by the `trap` | T47-32, T48-27 |
| T1 | 5 | Test builds in their own folder; `-Stop` by folder | T48-39, T48-49, T48-50, T48-51, T48-53 |
| T2 | 5 | Per-copy rule names | T48-45, T48-47 |
| T3 | 5 | Unelevated copy creates no rule | T48-46, T48-51 |
| T4 | 5 | Per-copy rule groups; a copy deletes only its own group | T48-44, T48-45, T48-47 |
| T5 | 5 | Only the live copy removes the old "System Monitor" rules | T48-45, T48-48 |
| T6 | 5 | Unelevated copy listens on `localhost` only | T48-46, T48-51 |
| T7 | 5 | A test build sets its own `DataPath` or leaves it empty | T48-17, T48-50 |
| ST1 | 6 | `DataPath`: full local path with a drive letter, not a network path; missing isn't a settings error | T48-07, T48-24 |
| ST2 | 6 | `LogRetentionDays` whole number 7 to 366 | T48-22 |
| ST3 | 6 | `MaintenanceHours` 0.25 to the maximum | T48-23 |
| ST4 | 6 | `MaintenanceMaxHours` 1 to 24 | T48-23 |
| ST5 | 6 | Invalid: one plain message, exit 2 | T48-25 |
| ST6 | 6 | In the example config with comments | T48-26, T51-06 |
| ST7 | 6 | No settings retired; existing validation unchanged | T47-29, T48-26 |
| Q1 | 7 | The listed Pester 5 tests exist | T47-33 (this table's check), and every row above |
| Q2 | 7 | CI: `shell: powershell`, pinned Pester and PSScriptAnalyzer with `-RequiredVersion`, `Add-Type` compiled, advisory until three green PRs | T47-03, T47-24, T47-25, T47-32 (the three-in-a-row switch is the owner's branch-protection change: UAT only) |
| Q3 | 7 | Locally: the same script plus the measuring tool on the test build | T47-27, T47-28 (the habit itself: UAT only) |
| Q4 | 7 | CHANGELOG and README in each PR | T47-34, T51-07, T51-08, T51-09 |
| Q5 | 7 | Release order: the launcher's release before v0.7.0 runs at boot | T51-04 (text); the ordering is the owner's: UAT only (T51-10) |
| Q6 | 7 | Rollback: an older SRRVRR ignores a newer file | T49-14, T50-29 |
| SEC1 | 8 | Firewall local network only, named and grouped per copy | T48-44, T48-48 |
| SEC2 | 8 | Only `POST /maintenance` changes anything | T47-36, T47-38, T50-36, T50-38 |
| SEC3 | 8 | Logs hold no names; logs writable only by SYSTEM and Administrators | T48-18, T49-25, T50-19, T50-44 |
| SEC4 | 8 | Code loads only from SRRVRR's own folder; launchers hash `modules\`, `web\` and the DLLs | T47-08, T47-10, T47-22, T51-04 |
| SEC5 | 8 | The stop signal can't be taken over | T48-33, T48-34, T48-35, T48-36 |
| SEC6 | 8 | Data never on a share; one copy per data folder | T48-01 to T48-09, T48-15 to T48-17 |
| DEP1 | Deps | `/stats` readers: every field stays; `Host` must be the server's own | T47-17, T47-18, T47-39, T49-22 |
| DEP2 | Deps | README update steps ("replace the code folders") and `-Stop` text | T48-68, T51-02 |
| DEP3 | Deps | Launcher contract: hashes, unlisted files, restart on crash codes only (3 in 10 min), the marker, the stop signal, 31-day log | T48-67, T51-01 to T51-04, T51-10 (the 31-day launcher log is the launcher's own: not testable here) |
| DEP4 | Deps | Windows PowerShell 5.1, C# 5, `HttpListener`, CIM, named events | T47-32, every K test (run in `powershell.exe` 5.1), CI's `shell: powershell` (T47-25) |

**Coverage of this table:** 135 requirement rows; every one has at least one test id. Automated tests exist for
all but B8, M8 (the accepted risk), S13 (the loss on a closed window), the three-in-a-row switch in Q2, the habit
in Q3, the release ordering in Q5, and the launcher's own log in DEP3: those are UAT or owner decisions, as noted.

## 8. Test data, environments and running the tests

### 8.1 Test data

- **All test data is generated or committed fixtures** (section 4.2): made-up names, titles and addresses only
  (documentation ranges and private examples), arbitrary drive letters, no paths, share names or account names from
  the owner's machines. `Test-NoPrivateInfo.ps1` runs over `tests\` too.
- **Canary words** for the privacy tests are fixed strings that can't occur by chance (for example
  `ZZCANARY-PLAYER-7Q`), listed once in `TestHelpers.psm1`.
- **Time:** unit tests use the fake clock at a fixed start (a date with no daylight-saving change in the next 31
  days); the daylight-saving tests set a start just before a change in a named time zone, passed in, not taken from
  the machine.
- **Large data** (oversize files, 5,000 events, 31 days of logs) is generated at test time into temp folders, not
  committed.
- **The v0.6.0 baseline** comes from the repo itself (`git show v0.6.0:SRRVRR.ps1` and a test build of the tag),
  so no capture from the live server is needed. If the tag name differs, `Parity.Tests.ps1` reads it from one
  variable at the top.

### 8.2 Environments

| Environment | Who | Elevated | What runs there | Never |
|---|---|---|---|---|
| The dev PC (a client PC) | Builder | No | Static, Unit, Integration, JS (if Node is installed), Smoke on random free ports, Perf on a test build on port 8091 | Elevated tests, firewall changes, anything under the live install, the live stop event |
| The server, test build | Owner | No (an elevated test copy only for the UAT steps that need it, by the owner) | UAT and the budget measurements (`Measure-SRRVRR.ps1`) on port 8091, from its own folder, with its own config and data folder | Touching the live copy's folder, config, data folder, firewall rules or stop event |
| GitHub-hosted Windows runner | CI | Yes (throwaway machine) | Everything automated, including `Elevated`; Perf informational | Reaching any of the owner's machines; secrets (none are needed) |

### 8.3 Running locally

The owner installs the pinned versions once, for their own account, side by side with the built-in Pester 3.4
(which stays, since Windows uses it):

```powershell
Install-Module Pester -RequiredVersion <x> -Scope CurrentUser -SkipPublisherCheck -Force
Install-Module PSScriptAnalyzer -RequiredVersion <y> -Scope CurrentUser -Force
```

Then, from the repo root, in Windows PowerShell 5.1:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Invoke-Checks.ps1                # static, unit, integration
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Invoke-Checks.ps1 -Smoke         # plus smoke on test builds
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Invoke-Checks.ps1 -Coverage      # plus out\coverage.xml
powershell -NoProfile -ExecutionPolicy Bypass -File tools\New-TestBuild.ps1 -Ref <branch> -Destination <test folder> -Port 8091
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Measure-SRRVRR.ps1 -BaseUrl http://localhost:8091 -Folder <test folder>
```

`Invoke-Checks.ps1` starts with `Import-Module Pester -RequiredVersion <x>` (the same pinned version as CI); if
it's missing it says how to install it and exits 2, so Pester 3.4 is never used by mistake. To run one file while
writing tests: `Import-Module Pester -RequiredVersion <x>; Invoke-Pester tests\History.Tests.ps1 -Output Detailed`.

Keep test folders short (for example a folder directly under the temp folder) because paths over 260 characters
fail on these machines; `New-TestBuild.ps1` and `Test-PathLength.ps1` check it.

### 8.4 Runtime budget

| Run | Target | Notes |
|---|---|---|
| Static | 10 s | Includes compiling the `Add-Type` blocks in one child process |
| Unit | 30 s | About 140 tests; no sleeps; fake clock |
| Integration | 60 s | Real listener, files, runspaces; `Wait-Until` with short timeouts |
| **Default local run (the three above)** | **under 2 minutes** | What the builder runs before every push |
| Smoke | about 3 minutes | Each copy needs up to 20 s to start; copies started in parallel where tests don't depend on each other |
| Elevated (CI) | 30 s | |
| Perf quick / soak | 2 min / 60 min | The soak only before a release (T50-56) |

`Invoke-Checks.ps1` prints each level's time; a level over its target by more than 50% is reported in the summary
so slow tests get noticed and fixed.

### 8.5 Flake policy

- **No timing by sleeping.** Unit tests use the fake clock; integration and smoke tests wait with `Wait-Until`
  and a timeout, and assert on state, not on elapsed time. Budget thresholds live only in Perf.
- **Isolation:** every test that writes uses its own temp folder and its own free port; every started process is
  tracked and killed in `AfterAll` (only processes whose command line points into that test's folder).
- **No retries in Unit or Integration.** Smoke and Perf may retry once, and a retried pass is reported as "flaky"
  in the summary.
- **A flaky test** (failed then passed on the same commit) gets an issue the same day and the `Flaky` tag, which
  keeps it running but non-blocking; it's fixed or deleted before the next release. A quarantined test still
  counts in coverage only if it passes.
- **Elevated tests** clean up what they created (rules, shares, events) even on failure, in `AfterAll`; the
  runner is thrown away anyway.

## 9. Risks and open questions

### 9.1 Risks

| Risk | Effect | Mitigation in this plan |
|---|---|---|
| Logic stays in `SRRVRR.ps1` or in runspace scriptblocks | Coverage can't reach it; the 100% target becomes meaningless | Rules in section 3; the function allow list in `Static.Tests.ps1`; review against the gap table |
| Ctrl+C on Windows PowerShell 5.1 with `-File` may end the script before a clean path can run (a `CancelKeyPress` handler can't run PowerShell code on its own thread) | S10 (exit 0, "stopped: Ctrl+C") may need `[Console]::TreatControlCAsInput` and reading keys in the request loop | T48-57 is a smoke test on a real console, early in #48; if it fails, the design changes before the rest is built |
| A full SRRVRR start may behave differently on the CI runner (no GPU, different counters, no Plex or Valheim, ETW on a VM) | Smoke and Elevated tests fail for reasons unrelated to the change | A spike in #47: start a test build on the runner and record what differs; tests that need hardware read capability flags from `/stats` and skip with a reason |
| Elevated tests are only as good as the runner | The firewall, share, ACL and ETW paths are never run on the server before UAT | UAT steps in `docs\uat\48-running-safely.md` cover them on the owner's machine with a test copy |
| Shared CI hardware | Perf numbers are noisy | Perf is informational on CI; budgets are judged on the owner's machine |
| Pester's coverage counts only the test runspace | Code called only from runspaces looks uncovered | All module functions are called directly by unit tests; integration tests prove the runspace wiring |
| `Host` allowlist (421) breaks a `/stats` reader that uses another name (an alias, a different DNS name) | A monitoring check on another machine stops working | DEP1 in the README (#51); T47-39; the owner checks their own readers during UAT 47 |
| Permissions fix on the live data folder removes write access the owner relied on | Manual cleanup or editing of logs needs an elevated prompt | Documented (T51-05); UAT 48 confirms the owner can still read |
| Long paths | Test folders under deep temp paths fail | Short temp roots; `Test-PathLength.ps1`; `New-TestBuild.ps1` refuses long destinations |
| Local Node not installed | JS tests run only in CI | Accepted; `Invoke-Checks.ps1` says "skipped: node not found" so it's visible |

### 9.2 Open questions for the owner

| Id | Question | Plan's proposal (what the tests pin until answered) |
|---|---|---|
| OQ1 | The spec's file table lists five modules. Extracting the rest of the logic needs `Settings.psm1`, `Control.psm1` and `Platform.psm1` too, and the two C# exception classes need one home both `SRRVRR.ps1` and the tests can compile. OK to add them to the spec's table? | Add the three modules; put the exception classes in `Settings.psm1` (compiled on import, guarded so a second import doesn't recompile) |
| OQ2 | How does a copy know it's a test copy (for its firewall names and group)? The spec says "by its folder" for `-Stop`, but not how the copy itself decides | `New-TestBuild.ps1` writes a marker file (`TESTBUILD.txt`) and a copy with that file is a test copy; the boot launcher never sees it because it only runs the live folder |
| OQ3 | UAT says "refresh the page on two PCs", but an unelevated test copy listens on `localhost` only | Two browsers on the server for routine UAT; an elevated test copy (with its own test rules) only for the UAT steps that need another PC |
| OQ4 | `Host` allowlist details: a full DNS name with a trailing dot, IPv6 zone ids, an address the machine gains after start (DHCP change) | Trailing dot refused; zone ids stripped before comparing; the list is rebuilt once a minute in the slow sampler |
| OQ5 | Cleanup boundary: is a file dated exactly `LogRetentionDays` days ago kept or deleted? | Deleted (today counts as day 1) |
| OQ6 | Crash-log line format | `yyyy-MM-ddTHH:mm:ss.fff+hh:mm LEVEL source: message`, one line per entry, newlines escaped |
| OQ7 | `history.json` whose newest reading is in the future (clock stepped back) | Ignored like a stale file, not renamed |
| OQ8 | A damaged or oversize `maintenance.json`: renamed `.bad` like history? | Yes, renamed `maintenance.json.bad`, Maintenance off, one error line |
| OQ9 | `/events` with no `days`, and the page's own request when `LogRetentionDays` is under 31 (the page asks `days=31`, which would get 400) | Missing `days` is 400; `/stats` (or the page) uses `min(31, LogRetentionDays)`, so the Flagged list keeps working when retention is shorter. Needs one line in the spec |
| OQ10 | A test build pointed at the live data folder: the live copy (elevated) has made the folder unwritable for others, so the test copy might see "read-only" and fall back instead of refusing | Check the lock first: opening `state\srrvrr.lock` gives a sharing violation while the live copy holds it, which is a refusal (exit 3) even when the folder is also read-only. T48-17 gets a second case with the folder read-only |
| OQ11 | `?since=` when more than 50 events are newer: the 50 just after the id (the page catches up over a few polls) or the newest 50? And is an id that has aged out of the 200 in memory "unknown"? | The 50 just after the id, with `eventsTruncated: true`; an id older than everything in memory is unknown (newest 50) |
| OQ12 | Maintenance rate limit counters: kept in memory only (reset on restart), and does "60 a day" reset at local midnight? | In memory; resets at local midnight |
| OQ13 | Which exact Pester 5 and PSScriptAnalyzer versions to pin | The newest stable 5.x and 1.x at the time #47 is built, written once at the top of `Invoke-Checks.ps1` and in the workflow |
| OQ14 | Branch protection: will the owner turn the checks into required status checks after three green PRs in a row? | Yes; `out\summary.md` reports the streak so the moment is clear |

**Smaller pinned values** (no question needed unless the owner disagrees): `tickMs` is `null` before the first
tick; memory is stored in history as a percentage of total RAM; history numbers keep 3 decimals; a stale
`history.json` is left as it is (not renamed); suppression windows are measured from the last kept event; the
query-recovered case logs a "back" event; a new drive appearing raises no event; a refused Maintenance change is
counted in one log line per minute.
