# UAT: <story number and title>

About 15 minutes. You test; nothing merges until you say so.

## Setup
1. Build a test copy of the PR's branch in its own folder, outside the live install:
   `.\tools\New-TestBuild.ps1 -Ref <branch> -Destination <test folder>`
2. Start it with `<test folder>\Start SRRVRR.bat`. Say **No** to the administrator prompt unless a step needs
   another PC. It listens on port 8091; the live copy keeps running on its own port.

## Steps
| # | Do | Expect | Checked for you |
|---|---|---|---|
| 1 | ... | ... | - |

Run `.\tools\Invoke-UatChecks.ps1 -Story <n>` for the steps marked "yes" above.

## Results
Paste into the PR:

```
Story #<n> UAT on <date>: steps 1-<n> pass / step <x> failed: <what happened>
```

## Clean up
Stop the test copy with `<test folder>\Stop SRRVRR.bat` and delete the folder.
