# UAT: #62 The version on the page and in /stats

About 10 minutes. You test; nothing merges until you say so.

## Setup
1. Build a test copy of the PR's branch in its own folder, outside the live install:
   `.\tools\New-TestBuild.ps1 -Ref feature/62-version -Destination <test folder>`
2. Start it with `<test folder>\Start SRRVRR.bat`. Say **No** to the administrator prompt unless a step needs
   another PC. It listens on port 8091; the live copy keeps running on its own port.

## Steps
| # | Do | Expect | Checked for you |
|---|---|---|---|
| 1 | Open `http://localhost:8091/` and look at the header, right after the "Up ..." text. | A version such as `test-feature/62-version+abc1234`, in amber. Hovering it says "Not a release build". | - |
| 2 | Open `http://localhost:8091/stats` in a browser tab. | The JSON has `"version"` with the same text, and still has the fields it had before (`uptime`, `cores`, `tickMs`, ...). | - |
| 3 | Stop the test copy, change `<test folder>\VERSION` to `v0.8.0`, start it again, reload the page. | The header says `v0.8.0` and it is not amber. | - |
| 4 | Stop it, delete `<test folder>\VERSION`, start it again. | The header says `dev`, in amber. | - |
| 5 | Stop it, put two lines in `<test folder>\VERSION`, start it again. | The header says `unknown`, in amber, and the startup lines (and the day's `logs\srrvrr-*.log`) say the file has more than one line. | - |
| 6 | In an administrator window, open the installed (live) copy's folder and check it has a `VERSION` file. | It does not yet, or it holds the previous tag. Put the new tag in it when you install v0.8.0, so the installed copy shows `v0.8.0`. | - |

## Results
Paste into the PR:

```
Story #62 UAT on <date>: steps 1-6 pass / step <x> failed: <what happened>
```

## Clean up
Stop the test copy with `<test folder>\Stop SRRVRR.bat` and delete the folder.
