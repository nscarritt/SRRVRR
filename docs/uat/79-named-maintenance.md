# UAT: #79 Maintenance limited to named PCs

About 15 minutes, in the same elevated sitting as #78's. You test; nothing merges until you say so.

## Setup
1. Build a test copy of the PR's branch in its own folder, outside the live install, on its own port:
   `.\tools\New-TestBuild.ps1 -Ref feature/79-named-maintenance -Destination <test folder> -Port 8091`
2. In the test copy's config set `NamedPCs` to one PC (its name and its fixed address), and leave a second PC out.
3. Start it with `<test folder>\Start SRRVRR.bat` as administrator (this is #78's sitting). The live copy keeps
   running on its own port. The startup lines must not say "No NamedPCs set".

## Steps
| # | Do | Expect | Checked for you |
|---|---|---|---|
| 1 | From the named PC, open the test copy's page | The header says "Viewing from <the PC's name>"; the Maintenance box is enabled | - |
| 2 | Tick **Maintenance** there | It turns on with an end time; untick it and it goes off | - |
| 3 | From the PC that is left out, open the page | The state and end time show, the box is disabled, and it says "Maintenance can be changed from a named PC. This PC is seen as <its address>." | - |
| 4 | At the server itself, open `http://localhost:8091` | The box works (the server counts as named) | - |
| 5 | From the PC that is left out, send a scripted POST to `/maintenance` with the right headers and a JSON body | 403 `{"error":"not a named PC"}`, and Maintenance did not change | - |
| 6 | Wait up to a minute, then look at the log | One line counts the refusal and names the address of the PC that was left out; there is no line per refusal | - |
| 7 | Stop the test copy, empty `NamedPCs`, start it again | The startup lines say "No NamedPCs set: Maintenance can be changed only at the server itself."; from the named PC the box is now disabled | - |

## Results
Paste into the PR:

```
Story #79 UAT on <date>: steps 1-7 pass / step <x> failed: <what happened>
```

## Clean up
Stop the test copy with `<test folder>\Stop SRRVRR.bat` (it removes its own rules) and delete the folder.