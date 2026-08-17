# Microsoft Schannel Cipher Hardening Rollout Plan

**Status:** Draft for technical and application-owner review

**Scope:** Windows Server 2019, Windows Server 2022, Windows Server 2025

**Protocol posture:** TLS 1.0 and TLS 1.1 globally disabled; TLS 1.2 explicitly enabled; TLS 1.3 uses the supported operating-system default

**Deployment method:** Administrative Templates GPO — **SSL Cipher Suite Order**

## 1. Executive summary

Security scans are identifying weak or deprecated cipher suites on Windows servers. The organization will define explicit Microsoft-aligned cipher-suite orders through Group Policy so that Schannel offers modern TLS 1.3 AES-GCM suites where supported and forward-secret ECDHE suites for TLS 1.2:

- Windows Server 2019: eight TLS 1.2 ECDHE suites—four AES-GCM suites followed by four AES-CBC/SHA-2 compatibility suites.
- Windows Server 2022 and 2025: two TLS 1.3 AES-GCM suites followed by the same eight TLS 1.2 ECDHE suites.

The change removes 3DES, NULL, PSK, static-RSA key exchange, CBC/SHA-1, and DHE suites from the normal server policy. It retains ECDHE/AES-CBC with SHA-256 or SHA-384 as a staged compatibility fallback. Removing `TLS_RSA_WITH_3DES_EDE_CBC_SHA` directly remediates the SWEET32 finding. Modern supported clients should continue to work. The principal compatibility risk is an older application, runtime, appliance, agent, proxy, or integration that supports TLS 1.2 but cannot negotiate any retained ECDHE suite.

Deployment will proceed in rings: laboratory validation, representative Windows application servers, broader Windows server waves, infrastructure services, and domain controllers last. Linux servers are not changed in this phase, but Linux-hosted applications that connect to Windows endpoints must participate in compatibility testing.

## 2. Objectives and success criteria

### Objectives

1. Eliminate security findings caused by weak or deprecated Schannel cipher suites.
2. Preserve TLS 1.2 compatibility through both RSA- and ECDSA-authenticated ECDHE suites.
3. Preserve TLS 1.3 on Windows Server 2022 and 2025.
4. Apply a controlled, auditable configuration using separate OS-scoped GPOs.
5. Detect application dependencies before broad enforcement.
6. Retain a rapid GPO rollback path.

### Success criteria

- The effective suite order matches the approved OS baseline after reboot.
- Security rescans no longer report SWEET32/3DES, NULL, static-RSA, CBC/SHA-1, or other excluded suites. CBC/SHA-2 results are reviewed separately because some scanner policies report all CBC suites even though AES-CBC is not affected by SWEET32.
- Inbound and outbound application transactions complete successfully.
- No sustained increase in Schannel, application, proxy, authentication, database, or monitoring errors.
- Domain-controller authentication, LDAP over TLS, Global Catalog TLS, replication-related integrations, and dependent applications pass validation before the DC rollout.

## 3. Current state

The source export contained 592 cipher-suite rows representing 26 anonymized endpoints. Each reset to `Order = 1` formed a new endpoint, and all 26 endpoint sequences were continuous.

Five configurations were present:

| Pattern | Endpoints | Current suites | Key characteristics |
|---|---:|---:|---|
| A | 15 | 23 | Modern suites first; also DHE, CBC/SHA-1, static RSA, and 3DES |
| B | 6 | 20 | Modern suites first; CBC/SHA-1 and static RSA; no DHE or 3DES |
| C | 3 | 31 | Pattern A plus PSK and NULL suites; requires additional review |
| D | 1 | 22 | Similar to Pattern A without 3DES |
| E | 1 | 12 | Closest to target; modern ECDHE plus DHE, without static RSA |

All endpoints already list ECDHE/AES-GCM suites near the top. Server 2022/2025-class configurations also list TLS 1.3 AES-GCM. This means the target is not a reversal of the preferred modern negotiation path; it removes fallback paths that older clients might still use.

Endpoints 3, 19, and 20 should receive specific ownership review because their export includes PSK and NULL suite entries. Microsoft notes that PSK suites require an application to request PSK explicitly, but application teams should still confirm that no intentional PSK integration exists.

## 4. Approved end state

### Windows Server 2019

| Priority | Cipher suite | Protocol |
|---:|---|---|
| 1 | `TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384` | TLS 1.2 |
| 2 | `TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256` | TLS 1.2 |
| 3 | `TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384` | TLS 1.2 |
| 4 | `TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256` | TLS 1.2 |
| 5 | `TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384` | TLS 1.2 |
| 6 | `TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256` | TLS 1.2 |
| 7 | `TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384` | TLS 1.2 |
| 8 | `TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256` | TLS 1.2 |

GPO value:

```text
TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384,TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256,TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384,TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256
```

Microsoft reference: <https://learn.microsoft.com/en-us/windows/win32/secauthn/tls-cipher-suites-in-windows-10-v1809>

Microsoft maps Windows Server 2019 to the Windows 10 version 1809 Schannel cipher documentation. TLS 1.3 suites are not included in this policy.

### Windows Server 2022 and Windows Server 2025

| Priority | Cipher suite | Protocol |
|---:|---|---|
| 1 | `TLS_AES_256_GCM_SHA384` | TLS 1.3 |
| 2 | `TLS_AES_128_GCM_SHA256` | TLS 1.3 |
| 3 | `TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384` | TLS 1.2 |
| 4 | `TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256` | TLS 1.2 |
| 5 | `TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384` | TLS 1.2 |
| 6 | `TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256` | TLS 1.2 |
| 7 | `TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384` | TLS 1.2 |
| 8 | `TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256` | TLS 1.2 |
| 9 | `TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384` | TLS 1.2 |
| 10 | `TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256` | TLS 1.2 |

GPO value:

```text
TLS_AES_256_GCM_SHA384,TLS_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384,TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256,TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384,TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256
```

Microsoft references:

- Server 2022: <https://learn.microsoft.com/en-us/windows/win32/secauthn/tls-cipher-suites-in-windows-server-2022>
- Server 2025: <https://learn.microsoft.com/en-us/windows/win32/secauthn/tls-cipher-suites-in-windows-server-2025>
- General Schannel suite guidance: <https://learn.microsoft.com/en-us/windows/win32/secauthn/cipher-suites-in-schannel>
- TLS management and GPO configuration: <https://learn.microsoft.com/en-us/windows-server/security/tls/manage-tls>

### Why these suites

- AES-GCM provides authenticated encryption.
- ECDHE provides forward secrecy for TLS 1.2.
- Both RSA and ECDSA authentication families are retained.
- AES-128 and AES-256 options are retained.
- The order follows the strongest portion of Microsoft's documented Schannel defaults.
- AES-GCM suites are prioritized ahead of CBC suites in accordance with Microsoft's HTTP/2 custom-order guidance.
- AES-CBC/SHA-2 is retained only as a staged TLS 1.2 compatibility fallback and may be removed later if telemetry and scanner policy permit.
- ChaCha20 is not included because Microsoft supports it on newer systems but does not enable it by default.

### Deliberately excluded

| Category | Reason |
|---|---|
| 3DES | Obsolete 64-bit block cipher and a common scanner finding |
| NULL | Does not encrypt application data |
| RC4, DES, export | Deprecated or cryptographically broken |
| Static RSA | No forward secrecy and commonly reported by scanners |
| CBC/SHA-1 | Legacy construction commonly reported as weak |
| DHE-RSA | Strong when correctly configured, but removed from newer Microsoft defaults and unnecessary when ECDHE is available |
| PSK | Not required for normal Schannel server operation; retain only for a documented application exception |
| ChaCha20 | Supported on newer Windows but not enabled by Microsoft by default |

## 5. Expected application impact

### Expected to continue working

- Supported Windows clients and servers.
- Current browsers.
- Supported .NET Framework/.NET releases using OS-default Schannel behavior.
- Current Java runtimes with ECDHE and AES-GCM enabled.
- Current OpenSSL, curl, web servers, reverse proxies, and load balancers.
- Applications using RSA certificates, because ECDHE-RSA is retained.
- Applications using ECDSA certificates, because ECDHE-ECDSA is retained.

### Higher-risk dependencies

- Older Java 6/7 or early Java 8 runtimes.
- Old .NET applications that override Schannel defaults or hard-code cipher behavior.
- Appliances, storage systems, printers, scanners, monitoring agents, backup agents, and embedded clients.
- Old OpenSSL or operating-system crypto libraries.
- Clients that offer TLS 1.2 but only static-RSA key exchange.
- Clients that offer only CBC suites.
- TLS interception, load balancers, API gateways, and reverse proxies with restricted backend cipher lists.
- Database, LDAP, SMTP, API, webhook, monitoring, or middleware connections where Windows acts as the TLS client.
- Any application intentionally using PSK on endpoints 3, 19, or 20.

The change affects outbound as well as inbound Schannel use. Testing must include calls made by the Windows server, not only calls received by it.

## 6. Application-owner readiness guide

### Information each owner must provide

1. Application name, owner, business criticality, and support contact.
2. Windows servers in scope and their OS versions.
3. All inbound TLS listeners, ports, load balancers, and proxies.
4. All outbound TLS dependencies, including APIs, databases, LDAP, SMTP, monitoring, and vendor services.
5. Client/runtime versions: .NET, Java, OpenSSL, Python, Node.js, Go, appliance firmware, or vendor product version.
6. Whether TLS, cipher suites, or Java security settings are explicitly overridden.
7. Whether the application uses RSA or ECDSA certificates.
8. A functional test procedure and a named tester for the change window.

### Windows checks

Display the locally effective Schannel order:

```powershell
Get-TlsCipherSuite | Select-Object -ExpandProperty Name
```

Confirm connectivity to a target port:

```powershell
Test-NetConnection -ComputerName service.example.org -Port 443
```

Perform an HTTPS request using the Windows curl client:

```powershell
curl.exe -v https://service.example.org/
```

Check recent Schannel events after application testing:

```powershell
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Schannel'; StartTime=(Get-Date).AddHours(-2)} |
    Select-Object TimeCreated, Id, LevelDisplayName, Message
```

Application owners should also inspect application-specific logs. A successful TCP connection does not prove that the TLS handshake or application transaction succeeded.

### Linux checks

Test TLS 1.2 with the retained RSA-authenticated ECDHE suites:

```bash
openssl s_client -connect service.example.org:443 -servername service.example.org \
  -tls1_2 -cipher 'ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256'
```

Test TLS 1.2 with ECDSA authentication when the endpoint uses an ECDSA certificate:

```bash
openssl s_client -connect service.example.org:443 -servername service.example.org \
  -tls1_2 -cipher 'ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-GCM-SHA256'
```

Test TLS 1.3 against Server 2022/2025:

```bash
openssl s_client -connect service.example.org:443 -servername service.example.org \
  -tls1_3 -ciphersuites 'TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256'
```

Test the real HTTP transaction:

```bash
curl --verbose --tlsv1.2 https://service.example.org/
```

Review local capabilities:

```bash
openssl version -a
openssl ciphers -v 'ECDHE+AESGCM'
```

### Java checks

Owners should confirm the vendor-supported Java version and inspect any explicit `https.cipherSuites`, `jdk.tls.disabledAlgorithms`, application-server connector, or JVM security configuration. For troubleshooting in a non-production test environment, Java TLS debugging can show the offered and negotiated suites:

```text
-Djavax.net.debug=ssl:handshake
```

This produces verbose and potentially sensitive diagnostic output; collect it only for a controlled test and protect the resulting logs.

### How owners can prevent issues

- Patch the OS, runtime, appliance firmware, and client libraries to supported versions.
- Remove application-level hard-coded legacy cipher lists.
- Ensure at least one retained ECDHE/AES-GCM suite is enabled on every client, proxy, and backend hop.
- Verify the certificate type matches an available authentication family: RSA with ECDHE-RSA or ECDSA with ECDHE-ECDSA.
- Update load-balancer frontend and backend cipher policies independently where applicable.
- Confirm Java disabled-algorithm policy does not accidentally remove all retained overlap.
- Test the complete business transaction, including authentication, database access, callbacks, and outbound API calls.
- Request a time-limited exception before enforcement if a vendor-supported upgrade cannot be completed.

## 7. Group Policy design

### GPO objects

1. **Schannel Strong Cipher Order — Server 2019**
   - Eight-suite TLS 1.2 order.
   - Scoped only to Windows Server 2019.
2. **Schannel Strong Cipher Order — Server 2022-2025**
   - Ten-suite TLS 1.2/TLS 1.3 order.
   - Scoped only to Windows Server 2022 and 2025.

Policy location:

```text
Computer Configuration
  Administrative Templates
    Network
      SSL Configuration Settings
        SSL Cipher Suite Order
```

### GPO controls

- Use security-group filtering or a controlled OU structure; document any WMI filter used.
- Exclude domain controllers until the dedicated DC phase.
- Do not combine protocol settings and suite ordering into an inseparable rollback unit.
- Record the approved comma-separated string in change management.
- Record GPO GUID, scope, link order, enforcement state, and responsible owner.
- Confirm no higher-precedence GPO or local policy overwrites the setting.
- Reboot is required before the new order is consistently effective.

### Verification after reboot

```powershell
$expected2019 = @(
    'TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384',
    'TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256',
    'TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384',
    'TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256',
    'TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384',
    'TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256',
    'TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384',
    'TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256'
)

$actual = @(Get-TlsCipherSuite | Select-Object -ExpandProperty Name)
Compare-Object -ReferenceObject $expected2019 -DifferenceObject $actual
```

For Server 2022/2025, use the corresponding ten-suite list as `$expected`.

Also verify policy application:

```powershell
gpresult.exe /h C:\Windows\Temp\Schannel-GPResult.html
```

## 8. Rollout planner

Dates should be assigned after owner and change-window confirmation.

| Phase | Scope | Entry criteria | Required validation | Exit criteria |
|---|---|---|---|---|
| 0 — Governance | Security, Windows engineering, network, application teams | Baseline approved | GPO design review; exception process; rollback review | Formal approval and named owners |
| 1 — Lab | Non-production Server 2019, 2022, and 2025 | GPOs created but narrowly scoped | Effective order, TLS 1.2/1.3 tests, scanner rerun, reboot behavior | No weak-suite finding; documented results |
| 2 — Representative pilots | Endpoint 13 plus one host from each export pattern | Application owner and test plan confirmed | Inbound/outbound transactions, Schannel logs, proxy/backend paths | No unresolved high-severity issue |
| 3 — Non-production Windows | Application QA/dev/test servers | Pilot success | Owner functional testing and security scan | Owner sign-off by application |
| 4 — Production application servers | Low-risk then medium/high criticality waves | Communications sent; rollback ready | Business transaction, monitoring, security scan | Stable observation window per wave |
| 5 — Windows infrastructure | Management, monitoring, middleware, file/print, PKI-adjacent services as applicable | Application waves stable | Service-specific validation | Stable infrastructure services |
| 6 — Domain-controller pilot | One controlled DC/site, avoiding fragile sites | LDAP/LDAPS inventory complete; application-owner tests ready | LDAPS, Global Catalog TLS, authentication, replication health, monitoring, dependent apps | DC pilot observation period complete |
| 7 — Domain controllers | Remaining DCs by site/ring | DC pilot approved | Per-DC health and dependency tests | All DCs compliant and stable |
| 8 — Closure | Entire Windows scope | Production and DC rollout complete | Enterprise rescan, exception reconciliation, evidence archive | Change closed and baseline operationalized |

### Suggested observation windows

- Lab and non-production: at least one complete application test cycle.
- Production application wave: 24–72 hours depending on criticality and transaction frequency.
- Domain-controller pilot: at least 72 hours and one representative business cycle.
- Low-frequency jobs: keep an exception or extended observation window until scheduled jobs have executed.

## 9. Domain-controller-specific plan

Domain controllers are last because failures may affect authentication and many applications simultaneously.

Before the DC pilot:

- Inventory LDAPS (`636`) and Global Catalog TLS (`3269`) consumers.
- Identify Linux LDAP clients, Java applications, appliances, network devices, identity products, and monitoring systems.
- Verify DC certificates and certificate chains.
- Test every known LDAP client against a non-production or pilot endpoint using ECDHE/AES-GCM.
- Confirm time synchronization, DNS, replication, SYSVOL, and normal authentication health.
- Ensure emergency access and GPO rollback procedures do not depend solely on a failing application path.

Example LDAPS test from Linux:

```bash
openssl s_client -connect dc01.example.org:636 -servername dc01.example.org \
  -tls1_2 -cipher 'ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256'
```

Example certificate/LDAP test from a domain management host:

```powershell
Test-NetConnection -ComputerName dc01.example.org -Port 636
```

Follow the network check with a real bind and directory query using the application's own LDAP library or an approved directory diagnostic tool.

Post-change DC validation should include:

```powershell
dcdiag.exe /e /c
repadmin.exe /replsummary
repadmin.exe /showrepl * /errorsonly
```

Also validate Kerberos/NTLM-dependent business authentication, LDAPS, Global Catalog TLS, certificate enrollment dependencies, monitoring, backups, and any identity federation or synchronization tools.

## 10. Monitoring and failure indicators

Monitor:

- Schannel events in the Windows System log.
- IIS, HTTP.sys, application-server, and reverse-proxy errors.
- HTTP 502/503 increases.
- LDAP bind and directory-query failures.
- Database connection or certificate-handshake failures.
- SMTP relay, webhook, API, middleware, monitoring, backup, and agent disconnects.
- Authentication latency or failure changes during the DC phase.
- Security scanner results after each representative ring.

Common TLS failure symptoms include abrupt connection resets, `handshake_failure`, `protocol_version`, `no shared cipher`, `could not create SSL/TLS secure channel`, and backend health-check failures.

## 11. Rollback plan

Rollback is accomplished by removing or disabling the new GPO link, restoring the previously approved policy state, refreshing policy, and rebooting affected systems.

1. Stop the affected rollout ring.
2. Capture timestamps, endpoints, application errors, Schannel events, and negotiated-suite evidence where possible.
3. Disable/unlink the cipher-order GPO for the affected scope or apply the approved rollback GPO.
4. Run `gpupdate /force`.
5. Reboot affected servers in accordance with the service recovery plan.
6. Confirm the previous effective suite order.
7. Re-test the failed business transaction.
8. Open a compatibility exception with a remediation owner and expiration date.

Rollback should not re-enable TLS 1.0 or TLS 1.1. If a legacy dependency cannot use the strong TLS 1.2 suites, treat it as an application exception rather than weakening protocols globally.

## 12. Exception process

An exception request must document:

- Application and business owner.
- Exact client/server connection and direction.
- Required legacy suite, supported protocol, and technical evidence.
- Vendor statement or upgrade constraint.
- Compensating controls.
- Remediation plan and target date.
- Explicit expiration date and security approval.
- Narrow GPO scope; no enterprise-wide weakening.

Exceptions should preserve TLS 1.2 and add only the minimum necessary suite for the minimum necessary hosts.

## 13. Evidence and records

Retain:

- Approved suite strings and GPO reports.
- Before/after `Get-TlsCipherSuite` output.
- Security scan evidence.
- Application-owner sign-offs.
- Pilot and production test records.
- Schannel monitoring results.
- Exception approvals and expiration dates.
- DC health evidence.
- Final change record and lessons learned.

## 14. References

- Microsoft — Cipher Suites in Schannel: <https://learn.microsoft.com/en-us/windows/win32/secauthn/cipher-suites-in-schannel>
- Microsoft — Windows Server 2019 / Windows 10 v1809 suites: <https://learn.microsoft.com/en-us/windows/win32/secauthn/tls-cipher-suites-in-windows-10-v1809>
- Microsoft — Windows Server 2022 suites: <https://learn.microsoft.com/en-us/windows/win32/secauthn/tls-cipher-suites-in-windows-server-2022>
- Microsoft — Windows Server 2025 and later suites: <https://learn.microsoft.com/en-us/windows/win32/secauthn/tls-cipher-suites-in-windows-server-2025>
- Microsoft — Manage TLS in Windows Server: <https://learn.microsoft.com/en-us/windows-server/security/tls/manage-tls>
- Microsoft — Deploy custom cipher-suite ordering: <https://learn.microsoft.com/en-us/troubleshoot/windows-server/windows-security/deploy-custom-cipher-suite-ordering>
- NIST SP 800-52 Rev. 2: <https://csrc.nist.gov/pubs/sp/800/52/r2/final>
- NVD — CVE-2016-2183 / SWEET32: <https://nvd.nist.gov/vuln/detail/CVE-2016-2183>
