<#
    Example: daily job that approves new devices and saves a CSV report.
    Schedule it with Task Scheduler, Azure Automation or a GitHub Actions self-hosted runner.
    Run once with -WhatIf first.
#>
param([switch]$WhatIf)

Import-Module "$PSScriptRoot/../src/IntuneLifecycle.psd1" -Force
Connect-IntuneLifecycle -ConfigPath "$PSScriptRoot/../config.json"

$report = Approve-EnrolledDevice -InventoryPath "$PSScriptRoot/inventory.example.csv" -LookbackHours 24 -WhatIf:$WhatIf
$report | Export-Csv "$PSScriptRoot/../logs/approval-$(Get-Date -Format yyyyMMdd).csv" -NoTypeInformation

$report | Group-Object Status | Select-Object Name, Count | Format-Table
