# UAT: #51 README: running SRRVRR at boot

About 15 minutes. You test; nothing merges until you say so. This checks that the README's
"Running SRRVRR at boot" section is enough to set up a boot launcher, using your launcher's own test
setup (a release of it that knows SRRVRR's `modules\` and `web\` files).

## Setup
1. Build a test copy of the PR's branch in its own folder, outside the live install:
   `.\tools\New-TestBuild.ps1 -Ref feature/51-readme -Destination <test folder>`
2. Point your launcher's test setup at `<test folder>\SRRVRR.ps1`, following only the README's
   "Running SRRVRR at boot" section.

## Steps
| # | Do | Expect |
|---|---|---|
| 1 | Read "Running SRRVRR at boot" and "Settings" in the README | You can tell how to start it, which files a hash check must cover, what each exit code means, how to stop it, and what to replace when updating, without looking anywhere else |
| 2 | Start the test copy the way the launcher does at boot | It starts; the launcher's file check passes with `modules\` and `web\` covered |
| 3 | End SRRVRR's process from Task Manager (a crash) | The launcher starts it again (up to 3 times in 10 minutes) |
| 4 | Run `<test folder>\Stop SRRVRR.bat` | It stops within 10 seconds and the launcher does not start it again (`state\stop-requested` was honoured) |
| 5 | Put `Port = 'abc'` in `<test folder>\SRRVRR.config.psd1` and start it through the launcher | It exits with code 2 and the launcher does not loop; remove the line afterwards |
| 6 | Add a stray file to `<test folder>\modules\` and start it through the launcher | The launcher refuses it as an unknown file |

## Results
Paste into the PR:

```
Story #51 UAT on <date>: steps 1-6 pass / step <x> failed: <what happened>
```

## Clean up
Stop the test copy with `<test folder>\Stop SRRVRR.bat`, undo the launcher's test setup, and delete
the folder.
