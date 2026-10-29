#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    One-time bootstrap: creates the dedicated Ansible service account and
    enables WinRM over HTTPS (TCP/5986) so an Ansible control node can manage
    this Windows Server.

.DESCRIPTION
    1. Service account
       - Local mode (default): creates/updates a local account (default
         svc_ansible) with a password you type (never echoed or logged),
         password never expires, user cannot change it, and adds it to the local
         Administrators group (by SID - locale independent). Sets
         LocalAccountTokenFilterPolicy=1, which Windows requires before a
         non built-in local admin can manage the host over WinRM.
       - Domain mode (-DomainAccount): the account must already exist in AD;
         it is only added to local Administrators. LocalAccountTokenFilterPolicy
         is not changed (domain accounts are not UAC-filtered).
    2. WinRM service set to Automatic and running
    3. Self-signed certificate (lab) or an existing cert via -CertificateThumbprint
    4. HTTPS listener bound to that certificate
    5. Basic auth and unencrypted traffic disabled
    6. Firewall rule for TCP/5986, optionally scoped to the controller IP(s)
    7. Optional: remove the HTTP (5985) listener and its firewall rules

.PARAMETER ServiceAccount
    Local account name, or DOMAIN\name with -DomainAccount. Default svc_ansible.

.PARAMETER DomainAccount
    Use an existing domain account instead of creating a local one.

.PARAMETER AllowedRemoteAddresses
    Who may connect to WinRM HTTPS. Default 'Any'. Example: 192.168.1.10

.PARAMETER CertificateThumbprint
    Thumbprint of an existing (CA-issued) cert in LocalMachine\My to bind.
    Omit to create/reuse a self-signed certificate (lab only).

.PARAMETER DisableHttpListener
    Remove the WinRM HTTP (5985) listener. Note: Server Manager remoting uses it.

.EXAMPLE
    .\Enable-WinRMForAnsible.ps1 -AllowedRemoteAddresses 192.168.1.10
.EXAMPLE
    .\Enable-WinRMForAnsible.ps1 -ServiceAccount 'CORP\svc_ansible' -DomainAccount -CertificateThumbprint 'AB12...' -DisableHttpListener
#>
[CmdletBinding()]
param(
    [string]   $ServiceAccount         = 'svc_ansible',
    [switch]   $DomainAccount,
    [string[]] $AllowedRemoteAddresses = @('Any'),
    [string]   $CertificateThumbprint,
    [int]      $CertValidityYears      = 2,
    [switch]   $DisableHttpListener
)

$ErrorActionPreference = 'Stop'
$AdminsSid = [Security.Principal.SecurityIdentifier]'S-1-5-32-544'

function Write-Step([string]$Text) { Write-Host $Text -ForegroundColor Cyan }

# ---------------------------------------------------------------------------
Write-Step "[1/7] Ansible service account: $ServiceAccount"
# ---------------------------------------------------------------------------
if (-not $DomainAccount) {
    if ($ServiceAccount -match '\\') { throw 'Use -DomainAccount for DOMAIN\name accounts.' }

    $pw1 = Read-Host "Password for $ServiceAccount" -AsSecureString
    $pw2 = Read-Host 'Confirm password' -AsSecureString
    $plain1 = [Net.NetworkCredential]::new('', $pw1).Password
    $plain2 = [Net.NetworkCredential]::new('', $pw2).Password
    if ($plain1 -cne $plain2) { throw 'Passwords do not match.' }
    if ($plain1.Length -lt 16) { throw 'Use at least 16 characters for a service account password.' }
    Remove-Variable plain1, plain2

    $user = Get-LocalUser -Name $ServiceAccount -ErrorAction SilentlyContinue
    if (-not $user) {
        New-LocalUser -Name $ServiceAccount -Password $pw1 -PasswordNeverExpires `
            -UserMayNotChangePassword -AccountNeverExpires `
            -FullName 'Ansible Service Account' `
            -Description 'Ansible automation over WinRM. Non-interactive. Managed account.' | Out-Null
        Write-Host '      Created local account.'
    } else {
        Set-LocalUser -Name $ServiceAccount -Password $pw1 -PasswordNeverExpires $true -UserMayChangePassword $false
        Enable-LocalUser -Name $ServiceAccount
        Write-Host '      Account exists - password rotated.'
    }

    # Required for non-RID-500 local admins over WinRM (UAC remote restrictions).
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
        -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force | Out-Null
    Write-Host '      LocalAccountTokenFilterPolicy = 1'
}

try {
    Add-LocalGroupMember -SID $AdminsSid -Member $ServiceAccount
    Write-Host '      Added to local Administrators.'
} catch [Microsoft.PowerShell.Commands.MemberExistsException] {
    Write-Host '      Already a member of local Administrators.'
}

# ---------------------------------------------------------------------------
Write-Step '[2/7] WinRM service -> Automatic + Running'
# ---------------------------------------------------------------------------
Set-Service   -Name WinRM -StartupType Automatic
Start-Service -Name WinRM
Enable-PSRemoting -SkipNetworkProfileCheck -Force | Out-Null

# ---------------------------------------------------------------------------
Write-Step '[3/7] Certificate'
# ---------------------------------------------------------------------------
if ($CertificateThumbprint) {
    $cert = Get-Item "Cert:\LocalMachine\My\$CertificateThumbprint"
    Write-Host "      Using provided cert $($cert.Thumbprint) ($($cert.Subject))"
} else {
    $fqdn = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
    $cert = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { $_.Subject -eq "CN=$fqdn" -and $_.NotAfter -gt (Get-Date).AddDays(30) } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
    if (-not $cert) {
        $cert = New-SelfSignedCertificate `
            -DnsName $fqdn, $env:COMPUTERNAME `
            -CertStoreLocation Cert:\LocalMachine\My `
            -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 `
            -KeyExportPolicy NonExportable `
            -NotAfter (Get-Date).AddYears($CertValidityYears)
        Write-Host "      Created self-signed cert $($cert.Thumbprint) (LAB ONLY)"
    } else {
        Write-Host "      Reusing self-signed cert $($cert.Thumbprint) (LAB ONLY)"
    }
}

# ---------------------------------------------------------------------------
Write-Step '[4/7] HTTPS listener on TCP/5986'
# ---------------------------------------------------------------------------
Get-ChildItem WSMan:\localhost\Listener |
    Where-Object { $_.Keys -contains 'Transport=HTTPS' } |
    Remove-Item -Recurse -Force
New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * `
    -CertificateThumbPrint $cert.Thumbprint -Force | Out-Null

# ---------------------------------------------------------------------------
Write-Step '[5/7] Hardening WinRM service auth'
# ---------------------------------------------------------------------------
Set-Item WSMan:\localhost\Service\Auth\Basic       -Value $false
Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $false

# ---------------------------------------------------------------------------
Write-Step '[6/7] Firewall rule for TCP/5986'
# ---------------------------------------------------------------------------
$ruleName = 'WinRM-HTTPS-In-TCP-Ansible'
Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -Name $ruleName `
    -DisplayName 'Windows Remote Management (HTTPS-In) - Ansible' `
    -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow `
    -Profile Any -RemoteAddress $AllowedRemoteAddresses | Out-Null
if ($AllowedRemoteAddresses -contains 'Any') {
    Write-Warning 'WinRM HTTPS is open to ANY address. Use -AllowedRemoteAddresses <controller IP> in production.'
}

# ---------------------------------------------------------------------------
Write-Step '[7/7] HTTP listener (5985)'
# ---------------------------------------------------------------------------
if ($DisableHttpListener) {
    Get-ChildItem WSMan:\localhost\Listener |
        Where-Object { $_.Keys -contains 'Transport=HTTP' } |
        Remove-Item -Recurse -Force
    Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' -ErrorAction SilentlyContinue | Disable-NetFirewallRule
    Write-Host '      HTTP listener removed; HTTP firewall rules disabled.'
} else {
    Write-Host '      Left unchanged (use -DisableHttpListener for HTTPS-only).'
}

Write-Host ''
Write-Host "Done. Put '$ServiceAccount' and its password in group_vars/windows/vault.yml." -ForegroundColor Green
Write-Host "HTTPS listener thumbprint: $($cert.Thumbprint)" -ForegroundColor Green
