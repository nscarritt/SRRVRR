# System Monitor settings
#
# Copy this file to SystemMonitor.config.psd1 (in the same folder as
# SystemMonitor.ps1) and edit the copy. SystemMonitor.config.psd1 is not part
# of the code, so updating System Monitor never overwrites your settings.
# Restart System Monitor after changing anything.
@{
    # --- Web page -------------------------------------------------------------

    # Port the dashboard is served on: http://<this-machine>:<Port>
    Port = 8099

    # Address to listen on:
    #   '+'            every address this machine has (default)
    #   '192.168.1.50' only this one address (must belong to this machine)
    #   'localhost'    only this machine can open the page
    ListenAddress = '+'

    # --- Windows Firewall -----------------------------------------------------

    # $true:  on every start, set up an inbound rule named "System Monitor"
    #         for Port, matching FirewallScope below (needs administrator)
    # $false: leave the firewall alone
    OpenFirewall = $true

    # Who the firewall lets in. The page is meant for local networks only
    # (see AllowPublicAddresses below for the one, at-your-own-risk exception).
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

    # Part of the graphics card's name, as shown in Device Manager >
    # Display adapters (e.g. 'T600' or 'RTX 4070'). '' to skip.
    PreferredGpu = ''

    # Which GPU to show when PreferredGpu is '' or isn't found:
    #   'Dedicated'  the graphics card (the GPU with the most video memory)
    #   'Integrated' the processor's built-in graphics (the least video memory)
    #   'All'        add up every GPU
    GpuFallback = 'Dedicated'

    # --- Processes table ------------------------------------------------------

    # Built-in rows under the graphs. Set one to $false to hide it.
    # The table disappears when every row is hidden.
    Processes = @{
        Valheim = $true
        Plex    = $true
    }
}
