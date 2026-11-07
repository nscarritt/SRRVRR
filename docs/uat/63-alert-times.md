# UAT: #63 Alert times, one 12-hour format, a 60-second clear

About 10 minutes. You test; nothing merges until you say so.

## Setup
1. Build a test copy of the PR's branch in its own folder, outside the live install:
   `.\tools\New-TestBuild.ps1 -Ref feature/63-alert-times -Destination <test folder>`
2. Start it with `<test folder>\Start SRRVRR.bat`. Say **No** to the administrator prompt unless a step needs
   another PC. It listens on port 8091; the live copy keeps running on its own port.

## Steps
| # | Do | Expect | Checked for you |
|---|---|---|---|
| 1 | Open the test copy's page and tick **Maintenance**. | The header says "Maintenance until" and a 12-hour time such as "3:30 PM", in your own time zone. No 24-hour times anywhere. | - |
| 2 | Untick **Maintenance**, then open the Flagged list. | The Maintenance on and off events are listed with a date and a 12-hour time, such as "Nov 6, 7:42 PM", newest first. | - |
| 3 | Make an alert happen: stop the test copy's Valheim check, or wait for a real event. | A banner slides down. Its last line is the time the event happened, in the same 12-hour format. | - |
| 4 | Watch that banner with the page in front. | It stays for a full minute, then closes by itself. Clicking x closes it sooner. | - |
| 5 | Make another alert, then switch to a different tab for two minutes and come back. | The banner is still there when you return, and closes about a minute after you return. | - |

## Results
Paste into the PR:

```
Story #63 UAT on <date>: steps 1-5 pass / step <x> failed: <what happened>
```

## Clean up
Stop the test copy with `<test folder>\Stop SRRVRR.bat` and delete the folder.
