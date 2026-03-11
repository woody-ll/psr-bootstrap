#Requires -RunAsAdministrator
#Requires -Version 5
#Requires -Modules Microsoft.PowerShell.LocalAccounts

[CmdletBinding()]

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]

Param (
    [bool]$DebugMode = $true,
    [String]$Username = "user",

    # temporary password for bootstrapping
    [String]$Password = "bootstrap_ssh_familyteam123"
)

Set-StrictMode -Version 3
$ErrorActionPreference = "Stop"



function Log($Message, [String]$Color = $null, $NoNewline = $false) {
    if ($Color) {
        $ExtraParms = @{"ForegroundColor" = $Color }
    }
    else {
        $ExtraParms = @{}
    }

    Write-Host $Message @ExtraParms -NoNewline:$NoNewline
}

function Debug($Message) {
    if ($DebugMode) {
        Log $Message -Color Cyan
    }
}

function Change($Message) {
    Log "! $Message" -Color Yellow
}

function Error($Message) {
    Log "ERROR: $Message" -Color Red
    Exit
}



function Set-Account($User) {
    $Name = $User.Name
    Debug "Setting up account `"$Name`""

    if (!$User.Enabled) {
        Change "Enabling account `"$Name`""
        $User | Enable-LocalUser -ErrorAction Stop
    }

    if ($null -ne $User.AccountExpires) {
        Change "Changing account expiration policy for `"$Name`""
        $User | Set-LocalUser -AccountNeverExpires -ErrorAction Stop
    }

    if ($null -ne $User.PasswordExpires) {
        Change "Changing password expiration policy for `"$Name`""
        $User | Set-LocalUser -PasswordNeverExpires -ErrorAction Stop
    }

    if ((Get-LocalGroupMember -SID S-1-5-32-544 | Select-Object -ExpandProperty SID) -notcontains $User.SID.Value) {
        Change "Changing group membership for `"$Name`" - adding account to `"Administrators`" local group"
        Add-LocalGroupMember -SID S-1-5-32-544 -Member $User -ErrorAction Stop
    }

    if ((Get-LocalGroupMember -SID S-1-5-32-545 | Select-Object -ExpandProperty SID) -contains $User.SID.Value) {
        Change "Changing group membership for `"$Name`" - removing account from `"Users`" local group"
        Remove-LocalGroupMember -SID S-1-5-32-545 -Member $User -ErrorAction Stop
    }

    Debug "OK: finished setting up account `"$Name`""
}

function New-Account {
    Debug "No user account found, will create one"

    try {
        $User = New-LocalUser -Name $Username -AccountNeverExpires -PasswordNeverExpires `
            -Password $(ConvertTo-SecureString $Password -AsPlainText -Force) -ErrorAction Stop
        Change "Created user account `"$Username`""
    }
    catch {
        Error "Caught an exception while creating user account `"$Username`": `"$_`""
    }

    return $User
}

function Process-Account {
    Debug "* Processing: Local user"

    $User = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
    if ($User) {
        Log "Found existing local user: `"$Username`""
    }
    else {
        $User = New-Account
    }

    Set-Account -User $User
}

function Process-DefaultShell {
    Debug "* Processing: DefaultShell"

    $Path = "HKLM:\SOFTWARE\OpenSSH"
    $Name = "DefaultShell"
    $Value = "$($Env:SystemRoot)\System32\WindowsPowerShell\v1.0\powershell.exe"

    try {
        Get-Item -Path $Path -ErrorAction Stop > $null
    }
    catch {
        Change "Creating registry path `"$Path`""
        New-Item -Path $Path -ErrorAction Stop
    }

    $ExistingValue = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $ExistingValue -or $null -eq $ExistingValue.DefaultShell) {
        Change "Adding registry key `"$Path\$Name`" with value `"$Value`""
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType String -Force -ErrorAction Stop > $null
    }
    elseif ($ExistingValue.DefaultShell -ne $Value) {
        Change "Setting registry key `"$Path\$Name`""
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Force -ErrorAction Stop > $null
    }
}

function Get-SSHServerService {
    $Service = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($null -eq $Service) {
        Error "OpenSSH Server service is missing"
    }

    return $Service
}

function Process-SSHServer {
    Debug "* Processing: SSH Server"

    $Cap = Get-WindowsCapability -Online -Name "OpenSSH.Server~*"
    if (($Cap | Measure-Object).Count -eq 0) {
        Error "Cannot find OpenSSH Server installation candidate"
    }
    elseif (($Cap | Measure-Object).Count -ge 2) {
        Error "Found multiple OpenSSH Server installation candidates"
    }

    $SSHCap = $Cap[0]
    if ($SSHCap.State -eq "NotPresent") {
        Change "Installing OpenSSH (package `"$($SSHCap.Name)`")"
        Add-WindowsCapability -Online -Name $($SSHCap.Name) -ErrorAction Stop
    }
    elseif ($SSHCap.State -ne "Installed") {
        Error "Invalid OpenSSH Server installation state: `"$($SSHCap.State)`""
    }

    $Service = Get-SSHServerService
    if ($Service.StartType -ne "Automatic") {
        Change "Changing OpenSSH startup type to Automatic"
        $Service | Set-Service -StartupType Automatic -ErrorAction Stop
    }
}

function Set-FirewallRule($Rule) {
    Debug "Setting up firewall rule `"$($Rule.Name)`""

    if (!$Rule.Enabled) {
        Change "Enabling OpenSSH firewall rule"
        $Rule | Enable-NetFirewallRule -ErrorAction Stop
    }
}

function Process-FirewallRule {
    Debug "* Processing: Firewall"

    $Rule = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
    if ($Rule) {
        Change "Removing old OpenSSH firewall rule"
        Remove-NetFirewallRule -Name "OpenSSH-Server-In-TCP"
    }

    Change "Creating OpenSSH firewall rule"

    New-NetFirewallRule `
        -Name "OpenSSH-Server-In-TCP" `
        -DisplayName "OpenSSH Server (sshd)" `
        -Description "OpenSSH Server TCP 22" `
        -Enabled True `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort 22 `
        -Action Allow `
        -Profile Domain,Private,Public `
        -RemoteAddress Any `
        -ErrorAction Stop

    Debug "Firewall rule configured"
}

function Start-SSHServer {
    $Service = Get-SSHServerService
    if ($Service.Status -ne "Running") {
        Change "Starting up OpenSSH service"
        $Service | Start-Service -ErrorAction Stop
    }
}



function Process-RDP {
    Debug "* Processing: RDP configuration"

    $IP = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notlike "127.*" -and $_.PrefixOrigin -ne "WellKnown" } |
        Select-Object -First 1 -ExpandProperty IPAddress)

    if (!$IP) {
        Error "Cannot determine host IPv4 address"
    }

    $LastOctet = ($IP.Split("."))[-1]
    $RdpPort = [int]("64$LastOctet")

    Change "Detected IP $IP, setting RDP port to $RdpPort"

    Set-ItemProperty `
        -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
        -Name "fDenyTSConnections" `
        -Value 0

    Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

    Set-ItemProperty `
        -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
        -Name "PortNumber" `
        -Value $RdpPort

    Get-NetFirewallRule -DisplayName "RDP Custom Port" -ErrorAction SilentlyContinue | Remove-NetFirewallRule

    New-NetFirewallRule `
        -DisplayName "RDP Custom Port" `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort $RdpPort `
        -Action Allow `
        -Profile Domain,Private,Public

    Restart-Service TermService -Force

    Change "RDP enabled on port $RdpPort"
}

Log "FamilyTeam Windows SSH remoting preparation script" -Color Green
Log "Debug mode: $(("disabled", "enabled")[$DebugMode])"

Process-Account
Process-SSHServer
Process-DefaultShell
Process-FirewallRule
Process-RDP

Start-SSHServer

Log "Completed" -Color Green

