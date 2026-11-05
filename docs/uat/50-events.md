# UAT: #50 Server-side alerts, the event log, Maintenance and the Flagged list

About 15 minutes. You test; nothing merges until you say so.

## Setup
1. Build a test copy of the PR's branch in its own folder, outside the live install:
   `.\tools\New-TestBuild.ps1 -Ref feature/50-events -Destination <test folder>`
2. Start it with `<test folder>\Start SRRVRR.bat`. Say **No** to the administrator prompt.
   It listens on port 8091; the live copy keeps running on its own port.
3. Open `http://localhost:8091` in two browsers (or a normal and a private window) side by side.
   Click **Sound off** in one of them to turn sound on.

## Steps
| # | Do | Expect | Checked for you |
|---|---|---|---|
| 1 | Look at both pages right after opening them | No banners pop up for anything that happened before; the **Flagged** card shows the started event and any warnings | - |
| 2 | Tick **Maintenance** in browser A | Both browsers show "Maintenance until HH:MM", about 2 hours from now, within a second or two | - |
| 3 | With Maintenance on, start or stop a Plex stream, or join or leave Valheim | No banner and no ding in either browser | - |
| 4 | Untick **Maintenance**, then do the same again | A banner in both browsers (and a ding in the one with sound on), worded as before | - |
| 5 | Tick and untick Maintenance twice within 10 seconds | The second change says "Too many changes, try again in a few seconds." and the box goes back | yes |
| 6 | Open `<test folder>\logs\events-<today>.jsonl` in Notepad | A line for each Maintenance change with the address that asked; any event during step 3 marked `"maintenance":true`; no player, user or device names, and no titles | yes |
| 7 | Tick Maintenance, run `Stop SRRVRR.bat` in the test folder, start it again, refresh | Maintenance is still on, with the same end time | yes |
| 8 | Close browser B, wait for a Plex or Valheim change, reopen it | The banner showed in browser A; browser B shows no old banner on opening, and the change is in the Flagged list if it was a warning | - |
| 9 | Refresh browser A | The sound choice is kept; Flagged lists the last 31 days, newest first | - |

Steps marked "yes" are also covered by the tests (T50-33, T50-19, T50-52), which pass on this branch;
nothing to run for them.

## Results
Paste into the PR:

```
Story #50 UAT on <date>: steps 1-9 pass / step <x> failed: <what happened>
```

## Clean up
Stop the test copy with `<test folder>\Stop SRRVRR.bat` and delete the folder.
