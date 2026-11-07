# UAT: #66 Clock changes and midnight

About 5 minutes. You test; nothing merges until you say so. There is nothing new to see on the page.

## Setup
1. Build a test copy of the PR's branch in its own folder, outside the live install:
   `.\tools\New-TestBuild.ps1 -Ref feature/66-clock-tests -Destination <test folder> -Port 8091`
2. Start it with `<test folder>\Start SRRVRR.bat`. Say **No** to the administrator prompt unless a step needs
   another PC. It listens on port 8091; the live copy keeps running on its own port.

## Steps
| # | Do | Expect | Checked for you |
|---|---|---|---|
| 1 | In the PR, read the test names in `tests\Clock.Tests.ps1` (T66-01 to T66-08) | Each names a clock-change or midnight case you agree matters | - |
| 2 | Open the PR's CI run | The Pester job is green and lists the T66 tests | - |
| 3 | Open `http://localhost:8091/events?days=2` | It answers with JSON (an `events` list, possibly empty), not an error | - |

Run `.\tools\Invoke-UatChecks.ps1 -Story 66` for the steps marked "yes" above.

## Results
Paste into the PR:

```
Story #66 UAT on <date>: steps 1-3 pass / step <x> failed: <what happened>
```

## Clean up
Stop the test copy with `<test folder>\Stop SRRVRR.bat` and delete the folder.
