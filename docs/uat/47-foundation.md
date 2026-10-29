# UAT: #47 Core foundation (modules, tests, CI, the page in its own files)

About 15 minutes. Nothing should look or behave differently from the live dashboard, apart from step 5.

## Setup
1. Build a test copy of this PR's branch in its own folder, outside the live install:
   `.\tools\New-TestBuild.ps1 -Ref feature/47-foundation -Destination <test folder>`
2. Start it with `<test folder>\Start SRRVRR.bat` and say **No** to the administrator prompt. It listens on
   port 8091 and needs no firewall change, so open it on the server itself.

Until #48, the test copy's `Stop SRRVRR.bat` stops every SRRVRR on the machine, the live one included. Close the
test copy's window instead (step 7).

## Steps
| # | Do | Expect | Checked for you |
|---|---|---|---|
| 1 | Open the live dashboard and `http://localhost:8091` side by side | Both load | - |
| 2 | Watch for a minute | The tiles, graphs and drives update the same way on both; the test copy's `/stats` has `tickMs` | yes |
| 3 | Compare the two pages closely | Same layout, colours, logos (CPU, memory, GPU, Valheim, Plex), Processes table and Storage card | yes (files load) |
| 4 | Join Valheim or start a Plex stream, if you can | The banner shows on both (banners are still worked out by the page in #47) | - |
| 5 | Open `http://localhost:8091/anything` | "Not found" (the live copy shows its page here; that's the one intended change) | yes |
| 6 | Click **Sound**, then reload | The sound choice is remembered | - |
| 7 | Close the test copy's window | The live dashboard keeps running | - |

Run `.\tools\Invoke-UatChecks.ps1 -Story 47` while the test copy runs (steps 2, 3 and 5).

## Results
Paste into the PR:

```
Story #47 UAT on <date>: steps 1-7 pass / step <x> failed: <what happened>
```

## Clean up
Delete the test folder.
