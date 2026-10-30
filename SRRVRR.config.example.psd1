# SRRVRR settings
#
# Copy this file to SRRVRR.config.psd1 (in the same folder as SRRVRR.ps1) and
# edit the copy. SRRVRR.config.psd1 is not part of the code, so updating
# SRRVRR never overwrites your settings. Restart SRRVRR after changing anything.
@{
    # --- Web page -------------------------------------------------------------

    # Port the dashboard is served on: http://<this-machine>:<Port>
    # The monitor always listens on this machine's own addresses; the console
    # shows both its name and its network IP when it starts.
    Port = 8099

    # --- Windows Firewall -----------------------------------------------------

    # Other PCs can only open the page through the firewall, so on every start
    # the monitor sets up an inbound rule named "SRRVRR" for Port
    # (needs administrator). This chooses who that rule lets in. The page is
    # meant for local networks only (see AllowPublicAddresses below for the
    # one, at-your-own-risk exception).
    #   'LocalSubnet' devices on the same local network (default)
    #   'Allowlist'   only the addresses in FirewallAddresses
    #   'Blocklist'   the local network, except the addresses in FirewallAddresses
    FirewallScope = 'LocalSubnet'

    # Addresses for Allowlist / Blocklist: single IPs, ranges or subnets, e.g.
    #   FirewallAddresses = @('192.168.1.20', '192.168.1.100-192.168.1.120', '10.0.0.0/24')
    # Only private addresses are accepted: 192.168.x.x, 10.x.x.x, 172.16-31.x.x,
    # 169.254.x.x, 127.x.x.x, and IPv6 fe80::/10 and fc00::/7.
    FirewallAddresses = @()

    # !!! SECURITY RISK - AT YOUR OWN RISK !!!
    # $true lets an Allowlist also contain specific PUBLIC (internet) IPs,
    # one single address each (no ranges or subnets). Anyone using an allowed
    # IP can see this page, which has NO password and NO encryption, once your
    # router forwards Port to this machine. Read "Security warning: public IP
    # addresses" in the README before turning this on. The authors accept no
    # liability for any consequences of enabling it.
    AllowPublicAddresses = $false

    # --- GPU ------------------------------------------------------------------

    # The graphics card to show, by its exact name as Windows reports it: the
    # "Name" under Display in dxdiag, or Device Manager > Display adapters,
    # e.g. 'NVIDIA T600' or 'AMD Radeon RX 7800 XT'. The console shows the
    # card in use when it starts, and lists every GPU's name if this one isn't
    # found. Leave it '' (or if the name isn't found) to use the GPU with the most
    # video memory. The GPU tile shows that card maker's logo (NVIDIA, AMD or
    # Intel).
    PreferredGpu = ''

    # --- Processes table ------------------------------------------------------

    # Built-in rows under the graphs. Set one to $false to hide it.
    # The table disappears when every row is hidden.
    Processes = @{
        Valheim = $true
        Plex    = $true
    }

    # The Valheim server's game port (the one players connect to). The player
    # count comes from the server's status query on the next port up.
    ValheimPort = 2456

    # --- Data: saved history, Maintenance and the logs ------------------------

    # The folder that holds SRRVRR's state\ and logs\ folders. Leave it '' to use
    # SRRVRR's own folder, or give a full local path with a drive letter, e.g.
    # 'D:\SRRVRR', to keep them on another drive. SRRVRR creates state\ and logs\
    # inside it but never the folder itself. If the folder is missing or can't be
    # written, SRRVRR uses its own folder instead and shows a flag. It refuses to
    # start if the folder is shared on the network.
    DataPath = ''

    # How many days of logs to keep (7 to 366). Old files are removed once the event log arrives.
    LogRetentionDays = 31

    # How long the Maintenance checkbox stays on before it switches itself off,
    # in hours (0.25 up to MaintenanceMaxHours).
    MaintenanceHours = 2

    # The longest Maintenance can stay on, in hours (1 to 24).
    MaintenanceMaxHours = 8
}
