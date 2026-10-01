<#
.SYNOPSIS
    Checks the org-level EWS settings in Exchange Online, one tenant at a time.

.DESCRIPTION
    For each tenant:
      - Asks for the App ID, then the admin account for that tenant.
      - Connects to Exchange Online (you sign in with the admin account for that tenant).
      - Reads EwsAllowedAppIDs (done first, because Microsoft says to set the list before EwsEnabled).
          Empty              -> sets it to our App ID.
          Has others, not us -> adds our App ID to the list.
          Has our App ID     -> does nothing.
        If the list cannot be read or saved, it stops and does NOT touch EwsEnabled.
      - Reads Get-OrganizationConfig EwsEnabled.
          Blank (null) -> sets it to $true.
          True         -> does nothing.
          False        -> writes an error. Does NOT change it.
      - Disconnects, so the next tenant can use a different account.
    At the end it asks if you want to do another tenant.

.EXAMPLE
    .\Check-EwsEnabled.ps1
#>

#Requires -Version 5.1

# Note: this does NOT reach the Exchange Online cmdlets (they live in their own module).
# That is why every Exchange Online call below has -ErrorAction Stop.
$ErrorActionPreference = 'Stop'

# Make sure the Exchange Online module is available
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Write-Host "ExchangeOnlineManagement module not found. Installing for current user..." -ForegroundColor Yellow
    Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber
}
Import-Module ExchangeOnlineManagement

# Module 3.10.0 and later is only supported on PowerShell 7.6 or later
$exoVersion = (Get-Module ExchangeOnlineManagement).Version
$psVersion  = $PSVersionTable.PSVersion
if ($PSVersionTable.PSEdition -eq 'Core' -and $exoVersion -ge [version]'3.10.0' -and
    ($psVersion.Major -lt 7 -or ($psVersion.Major -eq 7 -and $psVersion.Minor -lt 6))) {
    Write-Warning ("ExchangeOnlineManagement $exoVersion is only supported on PowerShell 7.6 or later. " +
                   "You are on PowerShell $psVersion. It may still work. To be safe, upgrade PowerShell to 7.6.")
}

# Only load the cmdlets we need. This keeps memory use low when we connect many times.
$exoCommands = 'Get-OrganizationConfig', 'Set-OrganizationConfig'

# Turn common error messages into a plain hint
function Get-ErrorHint {
    param([string]$Message)
    switch -Regex ($Message) {
        'A parameter cannot be found|is not recognized as the name of a cmdlet' {
            return "The account does not have the right admin role in this tenant. It needs Exchange Administrator."
        }
        'AADSTS' {
            return "The sign-in was blocked. Check the account, MFA, and Conditional Access."
        }
        'window handle|logon session does not exist' {
            return "Run the script in a normal PowerShell window. Do not use ISE, RunAs, or Task Scheduler."
        }
    }
}

# Read the EWS allow list as a clean array of strings (no blanks, no comma-joined values)
function Get-EwsAllowList {
    $policy = Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy -ErrorAction Stop
    if ($null -eq $policy) { throw "Could not read the EWS allow list. No change was made." }
    return @(@($policy.EwsAllowedAppIDs) |
             ForEach-Object { "$_" -split ',' } |
             ForEach-Object { $_.Trim() } |
             Where-Object { $_ })
}

# True if the list has this App ID (in any GUID format or letter case)
function Test-AppIdInList {
    param([string[]]$List, [guid]$AppId)
    foreach ($item in $List) {
        $parsed = [guid]::Empty
        if ([guid]::TryParse($item, [ref]$parsed) -and $parsed -eq $AppId) { return $true }
    }
    return $false
}

# Close any Exchange Online connection that is still open (for example, from before the script started).
# If an old connection stays open, its cmdlets could run against the wrong tenant.
function Disconnect-AllExo {
    if (Get-ConnectionInformation -ErrorAction SilentlyContinue) {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    }
}

do {
    Write-Host ""

    # Ask for the App ID for this tenant. Store it in the standard GUID format.
    do {
        $appIdText = (Read-Host "Enter the App ID (GUID) for this tenant").Trim()
        $parsedAppId = [guid]::Empty
        $isGuid = [guid]::TryParse($appIdText, [ref]$parsedAppId)
        if (-not $isGuid) { Write-Host "That is not a valid GUID. Try again." -ForegroundColor Red }
    } until ($isGuid)
    $appId = $parsedAppId.ToString()

    do {
        $upn = (Read-Host "Enter the admin account for this tenant (e.g. admin@contoso.onmicrosoft.com)").Trim()
    } until ($upn -match '@')

    try {
        Disconnect-AllExo

        # Connect. Using -UserPrincipalName makes sure the right account is used.
        Connect-ExchangeOnline -UserPrincipalName $upn -ShowBanner:$false -CommandName $exoCommands -ErrorAction Stop

        # There must be exactly one connection: the one we just made
        $connections = @(Get-ConnectionInformation -ErrorAction SilentlyContinue | Where-Object State -eq 'Connected')
        if ($connections.Count -eq 0) {
            throw "Not connected to Exchange Online. The sign-in did not finish."
        }
        if ($connections.Count -gt 1) {
            throw "More than one Exchange Online connection is open. Stopping so nothing is changed in the wrong tenant."
        }
        $conn = $connections[0]
        Write-Host "Signed in as: $($conn.UserPrincipalName)  Tenant ID: $($conn.TenantID)" -ForegroundColor Cyan

        # Exchange Online only loads the cmdlets this account has rights to use.
        # If these are missing, the account does not have the right admin role.
        $missing = @($exoCommands | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
        if ($missing) {
            throw ("Connected, but these cmdlets are not available: $($missing -join ', '). " +
                   "The account '$($conn.UserPrincipalName)' needs the Exchange Administrator " +
                   "(or Global Administrator) role in this tenant. Check the account is a member " +
                   "of that tenant, not a guest.")
        }

        $org = Get-OrganizationConfig -ErrorAction Stop
        if ($null -eq $org) { throw "Could not read the organization settings. No change was made." }
        Write-Host "Tenant: $($org.Name)" -ForegroundColor Cyan

        # --- EWS allowed App IDs ---
        # Microsoft says to set the allow list BEFORE EwsEnabled. From October 2026,
        # EwsEnabled True with an empty list blocks all EWS.
        Write-Host ""
        Write-Host "Checking EwsAllowedAppIDs..." -ForegroundColor Cyan
        $current = @(Get-EwsAllowList)

        if ($current.Count -eq 0) {
            Write-Host "Allow list is empty. Adding $appId..." -ForegroundColor Yellow
            Set-OrganizationConfig -EwsAllowedAppIDs $appId -ErrorAction Stop
            $changed = $true
        }
        elseif (Test-AppIdInList -List $current -AppId $appId) {
            Write-Host "Our App ID is already in the allow list. Nothing to do." -ForegroundColor Green
            $changed = $false
        }
        else {
            Write-Host "Allow list has other App IDs:" -ForegroundColor Yellow
            $current | ForEach-Object { Write-Host "  $_" }
            Write-Host "Adding $appId to the list..." -ForegroundColor Yellow
            $updated = @($current) + $appId
            Set-OrganizationConfig -EwsAllowedAppIDs ($updated -join ",") -ErrorAction Stop
            $changed = $true
        }

        if ($changed) {
            # Read the list back. If our App ID is not there, stop before EwsEnabled is touched.
            $saved = @(Get-EwsAllowList)
            if (-not (Test-AppIdInList -List $saved -AppId $appId)) {
                throw "The allow list did not save our App ID. EwsEnabled was NOT changed."
            }
            Write-Host "Done. Allow list is now:" -ForegroundColor Green
            $saved | ForEach-Object { Write-Host "  $_" }
        }

        # --- EwsEnabled ---
        Write-Host ""
        $org | Format-List EwsEnabled

        if ($null -eq $org.EwsEnabled) {
            Write-Host "EwsEnabled is blank. Setting it to True..." -ForegroundColor Yellow
            Set-OrganizationConfig -EwsEnabled $true -ErrorAction Stop

            # Check it worked
            $after = (Get-OrganizationConfig -ErrorAction Stop).EwsEnabled
            if ($after -eq $true) {
                Write-Host "Done. EwsEnabled is now True." -ForegroundColor Green
            }
            else {
                Write-Error "Tried to set EwsEnabled to True, but it now reads '$after'."
            }
        }
        elseif ($org.EwsEnabled -eq $true) {
            Write-Host "EwsEnabled is already True. Nothing to do." -ForegroundColor Green
        }
        else {
            Write-Error "EwsEnabled is set to FALSE for tenant '$($org.Name)'. EWS is blocked for the whole organisation. No change was made." -ErrorAction Continue
        }
    }
    catch {
        $message = $_.Exception.Message
        Write-Host "Something went wrong: $message" -ForegroundColor Red
        $hint = Get-ErrorHint $message
        if ($hint) { Write-Host "Hint: $hint" -ForegroundColor Yellow }
    }
    finally {
        # Always log out, so the next tenant starts clean and can use a different account
        Write-Host "Disconnecting from Exchange Online..." -ForegroundColor Cyan
        Disconnect-AllExo
        Write-Host "Disconnected." -ForegroundColor Cyan
    }

    $again = Read-Host "Do another tenant? (Y/N)"
} while ($again -match '^[Yy]')

Write-Host "Finished." -ForegroundColor Green
