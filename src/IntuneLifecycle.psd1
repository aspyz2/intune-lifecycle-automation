@{
    RootModule        = 'IntuneLifecycle.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '6b1f4c0e-3d2a-4e8b-9a51-2f7c8d9e0a11'
    Author            = 'Enzo Viana'
    Description       = 'Automates the Intune device lifecycle (approval, onboarding, offboarding) with Microsoft Graph.'
    PowerShellVersion = '7.2'
    RequiredModules   = @('Microsoft.Graph.Authentication')
    FunctionsToExport = @('Connect-IntuneLifecycle', 'Approve-EnrolledDevice', 'Start-Onboarding', 'Invoke-Offboarding')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Intune', 'MicrosoftGraph', 'Autopilot', 'EndpointManagement', 'Security')
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
