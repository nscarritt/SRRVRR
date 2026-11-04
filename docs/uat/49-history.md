# UAT: #49 15 minutes of graph history

About 15 minutes. You test; nothing merges until you say so.

## Setup
1. Build a test copy of the PR's branch in its own folder, outside the live install:
   `.\tools\New-TestBuild.ps1 -Ref feature/49-history -Destination H:\Repos\_testbuilds\SRRVRR-test-49`
2. Start it with `H:\Repos\_testbuilds\SRRVRR-test-49\Start SRRVRR.bat`. Say **No** to the administrator prompt.
   It listens on port 8091; the live copy keeps running on its own port. Leave it running 5 minutes.

## Steps
| # | Do | Expect | Checked for you |
|---|---|---|---|
| 1 | Open `http://localhost:8091` | The graphs start with the last minutes already drawn, not empty | - |
| 2 | Click **15 min** | The graphs show 15 minutes; the part before the start is empty; the button stays lit | - |
| 3 | Refresh the page, then open it in a second browser | The first browser is still on 15 min; the second starts on 60 s | - |
| 4 | Run `Stop SRRVRR.bat` in the test folder, wait 30 s, start it again, refresh | The earlier readings are back, then a gap of about 30-45 s, then new readings | yes |
| 5 | Stop it, type `oops` into `state\history.json` (Notepad), start it | It starts; `state\history.json.bad` holds `oops`; the graphs start empty; one `ERROR history` line in the log | yes |
| 6 | Stop it with the page open, wait 10 s, start it | The page says Disconnected, then fills in again by itself, with the gap | - |

Steps marked "yes" are also covered by the smoke tests T49-23 and T49-24, which pass on this branch; nothing to run for them.

## Results
Paste into the PR:

```
Story #49 UAT on <date>: steps 1-6 pass / step <x> failed: <what happened>
```

## Clean up
Stop the test copy with `H:\Repos\_testbuilds\SRRVRR-test-49\Stop SRRVRR.bat` and delete the folder.