@{
    RootModule        = 'AgpmScheduler.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '1fbe4ac7-72bb-4f70-90f3-d6a8af956d32'
    Author            = 'AGPM Operations'
    Description       = 'Queue and deployment support for scheduled AGPM GPO publishing.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-AgpmSchedulerConfig',
        'Initialize-AgpmSchedulerData',
        'Get-AgpmControlledGpo',
        'New-AgpmDeploymentJob',
        'Get-AgpmDeploymentJob',
        'Stop-AgpmDeploymentJob',
        'Invoke-AgpmDeploymentQueue'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
