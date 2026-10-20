#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Authentication

<#
    IntuneLifecycle
    Automates the device lifecycle in Microsoft Intune with Microsoft Graph:
      - Approve-EnrolledDevice : mark known devices as corporate and add them to a device group
      - Start-Onboarding       : prepare an Autopilot device for a new hire
      - Invoke-Offboarding     : revoke a leaver's sessions and wipe their devices for redeployment

    Every function that changes something supports -WhatIf and -Confirm.
#>

Set-StrictMode -Version Latest
$script:Config = $null
$script:GraphBase = 'https://graph.microsoft.com/v1.0'

#region Helpers ---------------------------------------------------------------

function Write-LifecycleLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'ACTION')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Information $line -InformationAction Continue
    if ($script:Config -and $script:Config.LogPath) {
        $dir = Split-Path $script:Config.LogPath -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null }
        Add-Content -Path $script:Config.LogPath -Value $line -WhatIf:$false
    }
}

function Invoke-GraphPaged {
    # Follows @odata.nextLink so callers always get the full result set.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uri)
    $results = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    while ($next) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject
        if ($page.PSObject.Properties.Name -contains 'value') { $page.value | ForEach-Object { $results.Add($_) } }
        else { $results.Add($page) }
        $next = if ($page.PSObject.Properties.Name -contains '@odata.nextLink') { $page.'@odata.nextLink' } else { $null }
    }
    return $results
}

function Assert-Connected {
    if (-not (Get-MgContext)) { throw 'Not connected. Run Connect-IntuneLifecycle first.' }
    if (-not $script:Config) { throw 'No configuration loaded. Run Connect-IntuneLifecycle -ConfigPath <file> first.' }
}

function Get-EntraDeviceObjectId {
    # Intune stores the Entra *deviceId*; group membership needs the Entra *object id*.
    param([Parameter(Mandatory)][string]$AzureADDeviceId)
    $uri = "$script:GraphBase/devices?`$filter=deviceId eq '$AzureADDeviceId'&`$select=id,displayName"
    $device = Invoke-GraphPaged -Uri $uri | Select-Object -First 1
    if (-not $device) { throw "Entra device not found for deviceId $AzureADDeviceId" }
    return $device.id
}

function Add-DeviceToGroup {
    param([Parameter(Mandatory)][string]$GroupId, [Parameter(Mandatory)][string]$DeviceObjectId)
    $body = @{ '@odata.id' = "$script:GraphBase/directoryObjects/$DeviceObjectId" }
    try {
        Invoke-MgGraphRequest -Method POST -Uri "$script:GraphBase/groups/$GroupId/members/`$ref" -Body $body | Out-Null
    }
    catch {
        if ($_.Exception.Message -match 'already exist') { return }   # idempotent
        throw
    }
}

#endregion

#region Connection ------------------------------------------------------------

function Connect-IntuneLifecycle {
    <#
    .SYNOPSIS
        Loads the configuration and connects to Microsoft Graph with app-only certificate auth.
    .EXAMPLE
        Connect-IntuneLifecycle -ConfigPath ./config.json
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateScript({ Test-Path $_ })][string]$ConfigPath)

    $script:Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    foreach ($key in 'TenantId', 'ClientId', 'CertificateThumbprint') {
        if (-not $script:Config.$key) { throw "Missing '$key' in $ConfigPath" }
    }

    # No secrets in code: the private key stays in the local certificate store.
    Connect-MgGraph -TenantId $script:Config.TenantId `
        -ClientId $script:Config.ClientId `
        -CertificateThumbprint $script:Config.CertificateThumbprint `
        -NoWelcome
    Write-LifecycleLog "Connected to tenant $($script:Config.TenantId)"
}

#endregion

#region Approve ---------------------------------------------------------------

function Approve-EnrolledDevice {
    <#
    .SYNOPSIS
        Approves recently enrolled devices whose serial number is in the asset inventory.
    .DESCRIPTION
        For each device enrolled in the last N hours:
          - serial found in the inventory CSV -> set ownership to corporate and add it to the approved device group
          - serial not found                  -> report it for manual review (never approved automatically)
        Returns one result object per device, so the output can be exported as a report.
    .EXAMPLE
        Approve-EnrolledDevice -InventoryPath ./examples/inventory.example.csv -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateScript({ Test-Path $_ })][string]$InventoryPath,
        [int]$LookbackHours = 24
    )
    Assert-Connected
    $inventory = @{}
    Import-Csv $InventoryPath | ForEach-Object { $inventory[$_.SerialNumber.Trim().ToUpper()] = $_ }

    $since = (Get-Date).ToUniversalTime().AddHours(-$LookbackHours)
    $select = 'id,deviceName,serialNumber,operatingSystem,enrolledDateTime,managedDeviceOwnerType,azureADDeviceId,userPrincipalName'
    $devices = Invoke-GraphPaged -Uri "$script:GraphBase/deviceManagement/managedDevices?`$select=$select" |
        Where-Object { [datetime]$_.enrolledDateTime -ge $since }

    foreach ($d in $devices) {
        $serial = "$($d.serialNumber)".Trim().ToUpper()
        $result = [pscustomobject]@{
            DeviceName = $d.deviceName; SerialNumber = $serial; User = $d.userPrincipalName
            OS = $d.operatingSystem; Status = $null
        }

        if (-not $inventory.ContainsKey($serial)) {
            $result.Status = 'NotInInventory'
            Write-LifecycleLog "Serial $serial ($($d.deviceName)) is not in the inventory: manual review" -Level WARN
            $result; continue
        }

        if ($PSCmdlet.ShouldProcess("$($d.deviceName) [$serial]", 'Set ownership to corporate and add to approved group')) {
            if ($d.managedDeviceOwnerType -ne 'company') {
                Invoke-MgGraphRequest -Method PATCH -Uri "$script:GraphBase/deviceManagement/managedDevices/$($d.id)" `
                    -Body @{ managedDeviceOwnerType = 'company' } | Out-Null
            }
            if ($d.azureADDeviceId) {
                $objectId = Get-EntraDeviceObjectId -AzureADDeviceId $d.azureADDeviceId
                Add-DeviceToGroup -GroupId $script:Config.ApprovedDeviceGroupId -DeviceObjectId $objectId
            }
            $result.Status = 'Approved'
            Write-LifecycleLog "Approved $($d.deviceName) [$serial]" -Level ACTION
        }
        else { $result.Status = 'WouldApprove' }
        $result
    }
}

#endregion

#region Onboarding ------------------------------------------------------------

function Start-Onboarding {
    <#
    .SYNOPSIS
        Prepares an Autopilot device for a new hire before it ships.
    .DESCRIPTION
        - Confirms the user exists and is enabled in Entra ID
        - Finds the Autopilot device by serial number
        - Assigns the user and the group tag, so the device enrolls with the right profile and policies
    .EXAMPLE
        Start-Onboarding -UserPrincipalName new.hire@contoso.com -SerialNumber 5CG1234XYZ -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$UserPrincipalName,
        [Parameter(Mandatory)][string]$SerialNumber,
        [string]$GroupTag
    )
    Assert-Connected
    if (-not $GroupTag) { $GroupTag = $script:Config.DefaultGroupTag }

    $user = Invoke-MgGraphRequest -Method GET -OutputType PSObject `
        -Uri "$script:GraphBase/users/$UserPrincipalName`?`$select=id,displayName,accountEnabled"
    if (-not $user.accountEnabled) { throw "User $UserPrincipalName is disabled. Check with HR before shipping a device." }

    $ap = Invoke-GraphPaged -Uri "$script:GraphBase/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$SerialNumber')" |
        Select-Object -First 1
    if (-not $ap) { throw "Serial $SerialNumber is not registered in Autopilot. Upload the hardware hash first." }

    if ($PSCmdlet.ShouldProcess("$SerialNumber -> $UserPrincipalName", "Assign user and group tag '$GroupTag'")) {
        Invoke-MgGraphRequest -Method POST -Uri "$script:GraphBase/deviceManagement/windowsAutopilotDeviceIdentities/$($ap.id)/assignUserToDevice" `
            -Body @{ userPrincipalName = $UserPrincipalName; addressableUserName = $user.displayName } | Out-Null
        Invoke-MgGraphRequest -Method POST -Uri "$script:GraphBase/deviceManagement/windowsAutopilotDeviceIdentities/$($ap.id)/updateDeviceProperties" `
            -Body @{ groupTag = $GroupTag } | Out-Null
        Write-LifecycleLog "Onboarding ready: $SerialNumber assigned to $UserPrincipalName (tag $GroupTag)" -Level ACTION
    }

    [pscustomobject]@{ User = $UserPrincipalName; SerialNumber = $SerialNumber; GroupTag = $GroupTag; AutopilotId = $ap.id }
}

#endregion

#region Offboarding -----------------------------------------------------------

function Invoke-Offboarding {
    <#
    .SYNOPSIS
        Secures a leaver's devices and sends them back to a ready-to-redeploy state.
    .DESCRIPTION
        - Revokes the user's sign-in sessions (refresh tokens)
        - Wipes each corporate Windows device, keeping Autopilot registration, so it can be redeployed without manual reimaging
        - Retires personal (BYOD) devices: removes only company data
        - Returns a report with each device and the action taken, for the asset return process
    .EXAMPLE
        Invoke-Offboarding -UserPrincipalName leaver@contoso.com -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$UserPrincipalName)
    Assert-Connected

    $user = Invoke-MgGraphRequest -Method GET -OutputType PSObject `
        -Uri "$script:GraphBase/users/$UserPrincipalName`?`$select=id,displayName"

    if ($PSCmdlet.ShouldProcess($UserPrincipalName, 'Revoke sign-in sessions')) {
        Invoke-MgGraphRequest -Method POST -Uri "$script:GraphBase/users/$($user.id)/revokeSignInSessions" | Out-Null
        Write-LifecycleLog "Sessions revoked for $UserPrincipalName" -Level ACTION
    }

    $select = 'id,deviceName,serialNumber,operatingSystem,managedDeviceOwnerType'
    $devices = Invoke-GraphPaged -Uri "$script:GraphBase/users/$($user.id)/managedDevices?`$select=$select"

    foreach ($d in $devices) {
        $corporateWindows = $d.managedDeviceOwnerType -eq 'company' -and $d.operatingSystem -eq 'Windows'
        $action = if ($corporateWindows) { 'Wipe' } else { 'Retire' }

        if ($PSCmdlet.ShouldProcess("$($d.deviceName) [$($d.serialNumber)]", $action)) {
            if ($corporateWindows) {
                # Full wipe. The Autopilot registration lives in the service, so the device
                # re-provisions itself on next boot with no manual reimaging.
                $body = @{ keepEnrollmentData = $false; keepUserData = $false }
                Invoke-MgGraphRequest -Method POST -Uri "$script:GraphBase/deviceManagement/managedDevices/$($d.id)/wipe" -Body $body | Out-Null
            }
            else {
                Invoke-MgGraphRequest -Method POST -Uri "$script:GraphBase/deviceManagement/managedDevices/$($d.id)/retire" | Out-Null
            }
            Write-LifecycleLog "$action sent to $($d.deviceName) [$($d.serialNumber)]" -Level ACTION
        }

        [pscustomobject]@{
            User = $UserPrincipalName; DeviceName = $d.deviceName; SerialNumber = $d.serialNumber
            OS = $d.operatingSystem; Ownership = $d.managedDeviceOwnerType; Action = $action
        }
    }
}

#endregion

Export-ModuleMember -Function Connect-IntuneLifecycle, Approve-EnrolledDevice, Start-Onboarding, Invoke-Offboarding
