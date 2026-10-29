# LDAP DC Failures

Splunk search that reports LDAP failures on domain controllers, grouped by failure type, client IP and bind identity:

- Bind and connection errors (1216)
- Rejected, unsigned and cleartext binds (2887, 2888, 2889)
- Channel binding failures (3039, 3040, 3041)
- LDAPS TLS handshake failures from Schannel (36874, 36887, 36888)

## Usage

Paste the contents of [`ldap-dc-failures.spl`](ldap-dc-failures.spl) into the Splunk search bar. The prerequisites, event reference and error codes are documented in the comments at the top of the file.

Pick a scope before running:

| Option | Scope | How |
|---|---|---|
| A (default) | Every DC whose host value contains the domain | Replace `contoso` with your domain |
| B | An explicit list of DCs | Comment out Option A and uncomment the `host IN (...)` line |
| C | Hosts reported as short names | Comment out Option A and uncomment the `ComputerName` filter |

## Requirements

- Splunk 8.1 or later (the search uses triple-backtick comments)
- LDAP diagnostic logging (`16 LDAP Interface Events` = 2) on each DC
- The Directory Service event log forwarded from the DCs
- Classic `WinEventLog` rendering; `XmlWinEventLog` needs different field extractions
