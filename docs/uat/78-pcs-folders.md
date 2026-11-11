# UAT: #78 PCs and folders (with #79, one elevated sitting)

About 20 minutes, by the owner, as administrator. Run it with #79's UAT.

## Setup
1. Build a test copy of the stacked branch in its own folder and on its own port (never the live copy's folder,
   port or firewall rule): `.\tools\New-TestBuild.ps1 -Ref <branch> -Destination <test folder> -Port 8091`.
2. In the test copy's `SRRVRR.config.psd1` set `NamedPCs = @( @{ Name = 'Test PC'; Addresses = @('<that PC's fixed address>') } )`.
3. Start it as administrator.

## Steps
| # | Do | Expect |
|---|---|---|
| 1 | From the named PC, copy a folder of files to a share | A row with the name "Test PC", the account, speeds, open files and a writing mark; opening it shows the folders (share, path, count) |
| 2 | Look for file names anywhere (page, `/stats`, the log in the test copy's `logs\`) | None: only folders and counts |
| 3 | From a PC not in `NamedPCs`, connect to a share | Its address in amber, and one `unknown-pc` entry in the log |
| 4 | Write a file from that PC | One banner "Unknown PC <address> is writing to the shares" and an `unknown-pc-write` flag with the account; disconnect and reconnect within 10 minutes raises nothing more |
| 5 | Set `TransferFolders = $false`, restart | Rows show counts only, no folders |
| 6 | With the load running, run `.\tools\Measure-SRRVRR.ps1 -Folder <test folder>` | CPU within the budget (if the CIM reads break it, the cadence becomes 10 s); `/stats` p95 at most 30 ms |
| 7 | Run `.\tools\Export-TransferSample.ps1` once while a PC has files open | A folder with three JSON files with names, addresses, accounts and paths replaced, and "Key shapes match the fixtures"; unelevated it refuses with a plain message |
| 8 | Stop the test copy with its own stopper | It removes its own firewall rule |