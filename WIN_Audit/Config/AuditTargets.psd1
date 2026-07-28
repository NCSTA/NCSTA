@{
    # This file is the supported change point for audit scope. Preserve item order
    # when a report is compared to a legacy result.
    TextEncoding = 'Default' # Legacy VBS used ANSI text, not real Excel workbooks.
    MissingPatchesMode = 'Disabled' # Disabled | OfflineScanPackage
    OfflineScanCabPath = 'C:\temp\wsusscn2.cab'

    # Standard privileged groups evaluated on a domain controller. Add approved
    # organization-specific administrative groups here before an audit run.
    PrivilegedGroupNames = @(
        'Administrators',
        'Domain Admins',
        'Enterprise Admins',
        'Schema Admins',
        'Account Operators',
        'Backup Operators',
        'Server Operators',
        'Print Operators',
        'Group Policy Creator Owners',
        'DNSAdmins',
        'DHCP Administrators',
        'Key Admins',
        'Enterprise Key Admins'
    )

    RegistryKeys = @(
        'HKCU:\Control Panel\Desktop',
        'HKLM:\SOFTWARE\Microsoft',
        'HKLM:\SOFTWARE\Microsoft\Driver Signing',
        'HKLM:\SOFTWARE\Microsoft\OLE',
        'HKLM:\SOFTWARE\Microsoft\OS/2 Subsystem for NT',
        'HKLM:\SOFTWARE\Microsoft\OS/2 Subsystem for NT\1.0',
        'HKLM:\SOFTWARE\Microsoft\OS/2 Subsystem for NT\1.0\config.sys',
        'HKLM:\SOFTWARE\Microsoft\TelnetServer',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnceEx',
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Setup\RecoveryConsole',
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon',
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server',
        'HKLM:\SOFTWARE\Policies\Microsoft\Cryptography',
        'HKLM:\SOFTWARE\Policies\Microsoft\Messenger\Client',
        'HKLM:\SOFTWARE\Policies\Microsoft\PCHealth\ErrorReporting\DW',
        'HKLM:\SOFTWARE\Policies\Microsoft\PCHealth\ErrorReporting',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Network Connections',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System',
        'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Providers\LanMan Print Services\Servers',
        'HKLM:\SYSTEM\CurrentControlSet\Control\SecurePipeServers\winreg',
        'HKLM:\SYSTEM\CurrentControlSet\Control\SecurePipeServers\winreg\AllowedPaths',
        'HKLM:\SYSTEM\CurrentControlSet\Control\SecurePipeServers\winreg\AllowedExactPaths',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Kernel',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\SubSystems',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp',
        'HKLM:\SYSTEM\CurrentControlSet\Lsa',
        'HKLM:\SYSTEM\CurrentControlSet\Services',
        'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters',
        'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters',
        'HKLM:\SYSTEM\CurrentControlSet\Services\LDAP',
        'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters',
        'HKLM:\SYSTEM\CurrentControlSet\Services\SimpTcp',
        'HKLM:\SYSTEM\CurrentControlSet\Services\SimpTcp\Parameters',
        'HKLM:\SYSTEM\CurrentControlSet\Services\SNMP\Parameters',
        'HKLM:\SYSTEM\CurrentControlSet\Services\SNMP\Parameters\ValidCommunities',
        'HKLM:\SYSTEM\CurrentControlSet\Services\SNMP\Parameters\PermittedManagers',
        'HKLM:\SYSTEM\CurrentControlSet\Services\TlntSvr',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\RPC',
        'HKCU:\Software\Policies\Microsoft\Windows\Control Panel\Desktop'
    )

    DirectoryTargets = @(
        '$env:SystemDrive\', '$env:SystemDrive\Inetpub', '$env:SystemDrive\Inetpub\AdminScripts',
        '$env:SystemDrive\Inetpub\mailroot', '$env:SystemDrive\Inetpub\wwwroot', '$env:SystemDrive\MSSQL2000',
        '$env:SystemDrive\MSSQL2000\MSSQL\JOBS', '$env:SystemDrive\MSSQL2000\MSSQL\LOG',
        '$env:SystemDrive\Program Files\Microsoft SQL Server\MSSQL\Binn',
        '$env:SystemDrive\Program Files\Microsoft SQL Server\MSSQL\Data', '$env:SystemDrive\Temp',
        '$env:windir', '$env:windir\Installer', '$env:windir\repair', '$env:windir\security',
        '$env:windir\System32', '$env:windir\System32\drivers', '$env:windir\System32\config',
        '$env:windir\System32\spool', '$env:windir\System32\spool\printers', '$env:windir\System32\spool\drivers',
        '$env:windir\System32\winevt\Logs'
    )

    # Retained in legacy order. Missing executables are reported as absent rather than failing the audit.
    FileTargets = @(
        'arp.exe','at.exe','attrib.exe','auditpol.exe','cacls.exe','cmd.exe','cisvc.exe','clipsrv.exe','cmd.exe','dcpromo.exe',
        'debug.exe','Dfssvc.exe','dmadmin.exe','edit.com','edlin.exe','eventcreate.exe','eventtriggers.exe','faxsvc.exe',
        'finger.exe','ftp.exe','gpupdate.exe','ipconfig.exe','ismserv.exe','llssrv.exe','locator.exe','lsass.exe','mnmsrvc.exe',
        'msdtc.exe','msiexec.exe','MSTask.exe','nbtstat.exe','net.exe','net1.exe','netdde.exe','netsh.exe','netstat.exe',
        'nslookup.exe','ntbackup.exe','ntfrs.exe','os2.exe','os2srv.exe','os2ss.exe','ping.exe','posix.exe','psxdll.dll',
        'psxss.exe','rcp.exe','reg.exe','regedt32.exe','regini.exe','regsvc.exe','regsvr32.exe','rexec.exe','route.exe',
        'rsh.exe','rsvp.exe','runonce.exe','sc.exe','SCardSvr.exe','secedit.exe','services.exe','smlogsvc.exe','snmp.exe',
        'snmptrap.exe','spoolsvce.exe','subst.exe','svchost.exe','syskey.exe','systeminfo.exe','telnet.exe','termsrv.exe',
        'tftp.exe','tlntsvr.exe','tlntsess.exe','tlntadmn.exe','tlntsvrp.dll','tracert.exe','ups.exe','UtilMan.exe','wbadmin.exe','xcopy.exe'
    )
}
