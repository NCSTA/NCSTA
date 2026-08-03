# Server Protocol Audit

A read-only PowerShell module for checking the local Windows server's:

- SSL/TLS client and server protocol status
- Effective TLS cipher-suite preference order
- Optional .NET Framework `SchUseStrongCrypto` status

The module does not change registry settings or cipher suites.

## Import and run

```powershell
Import-Module .\ServerProtocolAudit\ServerProtocolAudit.psd1
Get-Cipher
```

By default, the command returns one compact summary row per server:

```text
Computer                 Action Enabled (explicit)     Disabled (explicit)    Defaults Ciphers  Weak Review
--------                 ------ ------------------     -------------------    -------- -------  ---- ------
server1.domain.com       Yes    TLS 1.2                SSL 2.0, SSL 3.0               2      28     4     16
```

Audit one server:

```powershell
Get-Cipher server1.domain.com
```

Audit multiple servers:

```powershell
Get-Cipher server1.domain.com, server2.domain.com

'server1.domain.com', 'server2.domain.com' |
    Get-Cipher
```

> A semicolon ends a PowerShell command. Use a comma or pipeline for multiple
> servers.

Return only protocol status:

```powershell
Get-Cipher server1.domain.com -View Protocol |
    Format-Table Protocol, Role, Enabled, Configuration
```

Return every protocol and cipher record:

```powershell
Get-Cipher server1.domain.com -View All
```

Return cipher-suite order:

```powershell
Get-Cipher server1.domain.com -View CipherSuite |
    Format-Table Order, Name, Protocols, Assessment, Findings
```

Show suites that should be removed or reviewed during hardening:

```powershell
Get-Cipher server1.domain.com -View CipherSuite |
    Where-Object Assessment -ne 'Preferred' |
    Format-Table Order, Name, Assessment, Findings
```

Include .NET strong-cryptography settings:

```powershell
Get-Cipher server1.domain.com -IncludeStrongCrypto
```

Export simple data for comparison across servers:

```powershell
Get-Cipher server1.domain.com -View Protocol |
    Export-Csv .\protocol-status.csv -NoTypeInformation

Get-Cipher server1.domain.com -View CipherSuite |
    Export-Csv .\cipher-suite-order.csv -NoTypeInformation
```

## Install for native invocation

Copy the `ServerProtocolAudit` directory into a PowerShell module path, for example:

```powershell
$destination = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\ServerProtocolAudit'
Copy-Item .\ServerProtocolAudit $destination -Recurse
Import-Module ServerProtocolAudit
```

After installation, `Get-Cipher` is available by name in Windows PowerShell.
Remote targets require PowerShell remoting/WinRM and appropriate permissions.
Reading the local configuration normally does not require elevation.

## Interpreting results

`Configuration` is `Explicit` when SCHANNEL registry values define the state and
`OSDefault` when Windows controls it. For `OSDefault`, `Enabled` is blank because
defaults vary by Windows release and patch level; an absent key is not a hardening
guarantee.

`Enabled` reports the effective configured state; it does not test a live network
listener or prove that an application uses SCHANNEL. Cipher-suite results are the
local Windows SCHANNEL preference order returned by `Get-TlsCipherSuite`.

Cipher assessments are intentionally conservative screening hints:

- `Weak`: no encryption, RC2, RC4, or DES
- `Review`: static RSA key exchange, CBC mode, or SHA-1
- `Preferred`: none of those patterns were detected

Validate the final hardening baseline against application compatibility and your
organization's current security standard before changing production systems.
