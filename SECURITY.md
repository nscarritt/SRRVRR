# Security policy

## Supported versions

SRRVRR is a hobby project on `0.x`. Only the **latest release** gets security fixes; please
update before reporting.

## Reporting a vulnerability

**Please don't open a public issue for a security problem.** Report it privately instead:

1. Go to the [Security tab](https://github.com/nscarritt/SRRVRR/security) of this repository.
2. Choose **Report a vulnerability**.
3. Describe what you found, how to reproduce it, and which version you tested.

Only you and the maintainer can see the report. This is a one-person project, so replies are
best effort. I aim to acknowledge a report within a week and will keep you posted on a fix.
Unless you say otherwise, you'll be credited in the changelog once the fix is released.

## What counts as a vulnerability

Things worth reporting privately, for example:

- A way to read data other than the dashboard page and `/stats`, or to run code or commands
  on the server, through the web page or the listener.
- The firewall rules letting in addresses the settings don't allow, such as public IPs without
  `AllowPublicAddresses`.
- Secrets, such as the Plex token, ending up on the page, in `/stats` or in log output.
- Script injection (XSS) through process names, drive labels, Plex titles or similar values
  shown on the page.

## Known limitations (by design, not vulnerabilities)

SRRVRR is meant for trusted local networks. These are documented in the
[README security warning](README.md#security-warning-public-ip-addresses) and are not treated
as vulnerabilities:

- There is no password or login: anyone allowed by the firewall rules can view the page.
- The page is served over plain HTTP, without encryption.
- The page shows the computer's name, running programs and activity patterns.
