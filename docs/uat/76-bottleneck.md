# UAT: the Transfers card, the bottleneck and the shares (#76, T76-25)

Unelevated, on the server, with a test build (never the live copy): `tools\New-TestBuild.ps1 -Ref <branch>
-Destination <test folder> -Port <spare port>`, started without administrator, stopped with its own stopper.

1. Open the test build's page. A **Transfers** card sits below Storage. At rest the line says "Idle".
2. From another PC, copy a 1 to 2 GB file into a scratch folder on the code drive's share (never the photo or
   media drives; check the drive's free space first). A copy from the server to its own share does not move the SMB
   counters. The card updates every 5 seconds, so allow about 10 seconds. While it copies:
   - the share's row shows read and write speed and its open file, and the graph moves;
   - the bottleneck line names the share's drive ("Bottleneck: the share's drive (D:), ...") or the network link, or says
     "Not the server: the client or the path to it";
   - the small print always shows the link, drive and CPU numbers.
3. When the copy ends the line goes back to "Idle" within about 10 seconds.
4. The card's note says "PCs and folders need administrator", and the PC list is empty.
5. `/stats` has `transfers` and `/history` has `smbRead` and `smbWrite`.
6. Optionally, run the network test's SMB throughput test from another PC as a known load.

Pass when each step shows what it says.