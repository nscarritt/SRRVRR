# UAT: #48 Running safely (data folder, crash log, graceful stop, test copies)

About 15 minutes. The live SRRVRR keeps running the whole time; nothing here touches it.

## Setup
1. Build a test copy of this PR's branch in its own folder, with its own data folder:
   `.\tools\New-TestBuild.ps1 -Ref feature/48-running-safely -Destination <test folder> -DataPath <data folder>`
   (make `<data folder>` first; any local folder that isn't shared).
2. For the temperatures step, copy the live copy's `lib` folder (the sensor library) into `<test folder>`.

## Steps
| # | Do | Expect | Checked for you |
|---|---|---|---|
| 1 | Start `<test folder>\Start SRRVRR.bat` and say **Yes** to administrator | It starts on port 8091; the console says it's a test copy | yes |
| 2 | Open `http://localhost:8091` | The page as before; CPU and memory temperatures show (they need administrator and `lib`) | - |
| 3 | Look at the live dashboard from another PC | Still there: the test copy used its own firewall rule, "SRRVRR (test)" | yes (both rules) |
| 4 | Open `<data folder>\logs\srrvrr-<today>.log` | Every startup step, "History and logs go to <data folder>", "serving at ..." | yes |
| 5 | Run `<test folder>\Stop SRRVRR.bat` | It says SRRVRR saved and closed; the live SRRVRR keeps running; the log's last line is `stopped: requested (exit 0)` | yes (after) |
| 6 | Start it again, then press Ctrl+C in its window | It closes; the log's last line is `stopped: Ctrl+C (exit 0)` | yes (after) |
| 7 | Make `<data folder>` read-only for your account, start the copy, then undo it | It starts anyway, using `<test folder>` for its data, with a FLAG line in the log | - |
| 8 | Start a second test copy (another folder, port 8092) with the same `-DataPath`, while the first runs | It stops at once: "another SRRVRR is using the data folder", exit code 3 | - |

Run `.\tools\Invoke-UatChecks.ps1 -Story 48 -Folder <test folder> -DataFolder <data folder>` while the copy runs
(steps 1, 3, 4), and again after step 5 or 6 (the last log line).

## Results
Paste into the PR:

```
Story #48 UAT on <date>: steps 1-8 pass / step <x> failed: <what happened>
```

## Clean up
Stop the test copy with its `Stop SRRVRR.bat` and delete both folders. The "SRRVRR (test)" firewall rule can be
removed with `Remove-NetFirewallRule -DisplayName 'SRRVRR (test)'` (administrator).
