@{
    RootModule        = ''
    ModuleVersion     = '1.0.0'
    GUID              = '332e4a45-fe2e-4b0c-a2f3-7884b9515aa9'
    Author            = 'NCSTA'
    CompanyName       = 'NCSTA'
    Copyright         = '(c) NCSTA. All rights reserved.'
    Description       = 'Console-friendly VMware ESXi to Hyper-V migration helper toolkit.'
    PowerShellVersion = '5.1'

    NestedModules     = @(
        'Collect-VMwareMigrationData.psm1',
        'Configure-HyperVMigrationNic.psm1'
    )

    FunctionsToExport = @(
        'Invoke-VMwareMigrationDataCollection',
        'Invoke-HyperVMigrationNicConfiguration'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData       = @{
        PSData = @{
            Tags         = @('VMware', 'Hyper-V', 'SCVMM', 'Migration')
            ReleaseNotes = 'Initial console-friendly module manifest.'
        }
    }
}
