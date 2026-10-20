BeforeAll {
    Import-Module "$PSScriptRoot/../src/IntuneLifecycle.psd1" -Force
}

Describe 'IntuneLifecycle module' {
    It 'exports the four public functions' {
        $exported = (Get-Module IntuneLifecycle).ExportedFunctions.Keys
        $exported | Should -Contain 'Connect-IntuneLifecycle'
        $exported | Should -Contain 'Approve-EnrolledDevice'
        $exported | Should -Contain 'Start-Onboarding'
        $exported | Should -Contain 'Invoke-Offboarding'
    }

    It '<Name> supports -WhatIf' -ForEach @(
        @{ Name = 'Approve-EnrolledDevice' }
        @{ Name = 'Start-Onboarding' }
        @{ Name = 'Invoke-Offboarding' }
    ) {
        (Get-Command $Name).Parameters.Keys | Should -Contain 'WhatIf'
    }

    It 'Invoke-Offboarding asks for confirmation by default' {
        $attr = (Get-Command Invoke-Offboarding).ScriptBlock.Attributes |
            Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
        $attr.ConfirmImpact | Should -Be 'High'
    }

    It 'refuses to run before connecting' {
        { Approve-EnrolledDevice -InventoryPath "$PSScriptRoot/../examples/inventory.example.csv" } |
            Should -Throw
    }
}
