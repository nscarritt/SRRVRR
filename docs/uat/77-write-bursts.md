# UAT: #77 Write bursts

About 15 minutes. You test; nothing merges until you say so. Run this after #76 (the Transfers card and the wiring
it carries) is in the build, unelevated, on the server itself.

## Setup
1. Build a test copy of the PR's branch in its own folder, outside the live install:
   `.\tools\New-TestBuild.ps1 -Ref feature/77-write-bursts -Destination <test folder> -Port 8091`
2. In `<test folder>\SRRVRR.config.psd1` set `BurstQuietMinutes = 1` (and leave `BurstFiles` at 500).
3. Start it with `<test folder>\Start SRRVRR.bat`. Say **No** to the administrator prompt. It listens on port 8091;
   the live copy keeps running on its own port.
4. Make a scratch folder on a share on the code drive (never the photo or media drives), and two folders of small
   files: one of 600 files, one of 300.

## Steps
| # | Do | Expect | Checked for you |
|---|---|---|---|
| 1 | Open `http://localhost:8091/` and leave it open. Copy the 600-file folder into the scratch folder through the server's own loopback name | One banner: "Write burst from a PC (needs administrator)", with the files and the share | - |
| 2 | Open the Flagged list | A `write-burst` flag with the same text, with no folders and no file names | - |
| 3 | Wait about two minutes after the copy ends | A `write-burst-ended` flag in the Flagged list (no banner): the files, the bytes, the duration | - |
| 4 | Copy the 300-file folder into the scratch folder | No banner and nothing new in the Flagged list | - |
| 5 | Copy the 600-file folder again and, while it is still copying, stop the test copy with `<test folder>\Stop SRRVRR.bat` | The newest file in `<test folder>\logs` has a `write-burst-ended` line with `"reason":"stopped"` | - |
| 6 | Open `<test folder>\logs` and search the events file for a file name from the copied folders | No file name appears anywhere in it | - |

## Results
Paste into the PR:

```
Story #77 UAT on <date>: steps 1-6 pass / step <x> failed: <what happened>
```

## Clean up
Stop the test copy with `<test folder>\Stop SRRVRR.bat` (if it is still running), delete the test folder and the
scratch folder.
