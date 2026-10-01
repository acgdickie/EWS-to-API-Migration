# EWS to API Migration

`Check-EwsEnabled.ps1` prepares Exchange Online tenants for Microsoft's EWS changes.
For each tenant it adds your app to the EWS allow list and makes sure EWS is turned on.

## What the script does

For each tenant, the script:

1. Asks for the **App ID** (a GUID), then the **admin account**.
2. Connects to Exchange Online with that account.
3. Reads the EWS allow list (`EwsAllowedAppIDs`):

   | Allow list now               | What the script does                          |
   |------------------------------|-----------------------------------------------|
   | Empty                        | Sets it to your App ID                        |
   | Has other App IDs, not yours | Adds your App ID and keeps the others         |
   | Already has your App ID      | Nothing                                       |

4. Reads `EwsEnabled`:

   | `EwsEnabled` now | What the script does                     |
   |------------------|------------------------------------------|
   | Blank            | Sets it to `True`                        |
   | `True`           | Nothing                                  |
   | `False`          | Shows an error. Does **not** change it   |

5. Disconnects, so you can sign in to the next tenant with a different account.
6. Asks if you want to do another tenant.

The allow list is set **before** `EwsEnabled`, which is the order Microsoft recommends.

## Requirements

- The **ExchangeOnlineManagement** PowerShell module. If it is missing, the script installs it for the current user.
- A supported PowerShell version:
  - Module 3.10.0 or later needs **PowerShell 7.6 or later**, or Windows PowerShell 5.1.
  - On PowerShell 7.4, use module 3.9.2 or earlier, or upgrade PowerShell.
- An admin account with the **Exchange Administrator** (or Global Administrator) role in each tenant.
  The account must be a member of the tenant, not a guest.
- A normal interactive PowerShell window. ISE, RunAs and Task Scheduler are not supported.

## How to run

```powershell
cd "C:\path\to\EWS-to-API-Migration"
.\Check-EwsEnabled.ps1
```

If Windows blocks the script, allow scripts for this window only, then run it again:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## Safety checks

The script stops and makes **no change** to a tenant when:

- It cannot read the allow list or the organization settings.
- The allow list does not save your App ID. In this case `EwsEnabled` is not changed.
- More than one Exchange Online connection is open. Old connections are closed before each sign-in.
- The account does not have the cmdlets it needs (wrong role).

Other App IDs that are already in the allow list are always kept.
App IDs are compared as GUIDs, so letter case and braces (`{...}`) do not make a duplicate.

## Good to know

- **Allow list changes can take up to 24 hours** to take effect. `EwsEnabled` changes take about 1 hour.
- When `EwsEnabled` is `True` and the allow list has entries, **only the apps in the list can use EWS** in that tenant.
  Add every app that still needs EWS to the list.
- From October 2026, Microsoft blocks EWS when `EwsEnabled` is `True` and the allow list is empty.
  Tenants left blank are moved to `False` in a phased rollout.

## Troubleshooting

| Message                                                   | What to do                                                        |
|-----------------------------------------------------------|-------------------------------------------------------------------|
| `... is not recognized as the name of a cmdlet`            | The account needs the Exchange Administrator role in that tenant. |
| `A parameter cannot be found ...`                          | Same as above: the account's role is too limited.                 |
| `AADSTS...`                                                | The sign-in was blocked. Check the account, MFA and Conditional Access. |
| `A window handle must be configured` / `logon session does not exist` | Run the script in a normal PowerShell window.          |

## Reference

- [Set-OrganizationConfig (Microsoft Learn)](https://learn.microsoft.com/powershell/module/exchangepowershell/set-organizationconfig)
