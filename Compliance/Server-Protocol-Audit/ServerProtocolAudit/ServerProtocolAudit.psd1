@{
    RootModule        = 'ServerProtocolAudit.psm1'
    FormatsToProcess  = @('ServerProtocolAudit.Format.ps1xml')
    ModuleVersion     = '1.0.0'
    GUID              = 'be0992f8-fadf-428d-85c1-92289248e941'
    Author            = 'Infrastructure Operations'
    CompanyName       = ''
    Copyright         = '(c) Infrastructure Operations. All rights reserved.'
    Description       = 'Read-only audit of Windows SCHANNEL protocol status and TLS cipher-suite order.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Get-Cipher', 'Get-ServerProtocolAudit')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags = @('TLS', 'SSL', 'SCHANNEL', 'CipherSuite', 'WindowsServer')
        }
    }
}
