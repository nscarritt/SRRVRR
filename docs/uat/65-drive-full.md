# UAT: #65 The drive-almost-full alert

About 10 minutes. You test; nothing merges until you say so.

## Setup
1. Build a test copy of the PR's branch in its own folder, outside the live install:
   `.\tools\New-TestBuild.ps1 -Ref feature/65-drive-full -Destination <test folder> -Port 8091`
2. Note a drive's used percent on the page (Storage card) and round it down to a whole number, call it N.
3. Copy `SRRVRR.config.example.psd1` to `SRRVRR.config.psd1` in the test folder. Start it with
   `<test folder>\Start SRRVRR.bat`. Say **No** to the administrator prompt. It listens on port 8091; the live
   copy keeps running on its own port.

## Steps
| # | Do | Expect | Checked for you |
|---|---|---|---|
| 1 | Open `http://localhost:8091` with the default settings | Every drive's bar is as before: plain below 85%, amber from 85%, red from 95% | - |
| 2 | Stop it, set `DriveWarnPercent` to N (at least 50, below `DriveFullPercent`), start it, refresh, wait a minute | That drive's bar is amber, and one banner says "Drive X: is N% full" with the free GB | - |
| 3 | Wait another minute | No second banner for the same drive | - |
| 4 | Open `logs\events-<today>.jsonl` | One `drive-filling` line with only `letter`, `usedPercent` and `freeGB` | - |
| 5 | Stop it, set `DriveWarnPercent` back to 85, start it, refresh | The bar is plain again and no banner appears | - |
| 6 | Stop it, set `DriveWarnPercent = 101`, start it | It refuses to start with one plain message naming `DriveWarnPercent` and "50 to 99" (exit code 2) | - |
| 7 | Set `DriveWarnPercent = 96` with `DriveFullPercent = 95` and start it | It refuses with one message saying warn must be lower than full | - |

## Results
Paste into the PR:

```
Story #65 UAT on <date>: steps 1-7 pass / step <x> failed: <what happened>
```

## Clean up
Stop the test copy with `<test folder>\Stop SRRVRR.bat` and delete the folder.