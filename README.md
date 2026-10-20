# System Monitor

A tiny live CPU / memory / GPU / network dashboard for Windows, in the spirit of
Task Manager's Performance tab. One PowerShell script, nothing to install.

## Use

1. Copy `SystemMonitor.ps1` and `Start System Monitor.bat` to the machine you want to watch.
2. Right-click `Start System Monitor.bat` > **Run as administrator**
   (the first run adds a firewall rule allowing port 8099 from the local network only).
3. Open `http://<that-machine>:8099` from any browser on your network.

Close the window to stop it. Run `SystemMonitor.ps1 -Port <n>` to use a different port.
