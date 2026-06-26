#Requires -RunAsAdministrator
#Requires -Version 5

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
Param (
    [bool]$DebugMode = $true
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


function Process-RDP {
    Debug "* Processing: RDP configuration"

    # Получаем IPv4 адрес
    $IP = (Get-NetIPAddress -AddressFamily IPv4 `
        | Where-Object { $_.IPAddress -notlike "127.*" -and $_.PrefixOrigin -ne "WellKnown" } `
        | Select-Object -First 1 -ExpandProperty IPAddress)

    if (!$IP) {
        Error "Cannot determine host IPv4 address"
    }

    $LastOctet = ($IP.Split("."))[-1]
    $RdpPort = "64$LastOctet"

    Change "Detected IP $IP, setting RDP port to $RdpPort"

    # Включаем RDP
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
        -Name "fDenyTSConnections" -Value 0

    Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

    # Меняем порт RDP
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
        -Name "PortNumber" -Value $RdpPort

    # Удаляем старые правила если есть
    Get-NetFirewallRule -DisplayName "RDP Custom Port" -ErrorAction SilentlyContinue | Remove-NetFirewallRule

    # Добавляем firewall правило
    New-NetFirewallRule `
        -DisplayName "RDP Custom Port" `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort $RdpPort `
        -Action Allow `
        -Profile Domain,Private,Public `
        -ErrorAction Stop

    # Рестарт сервиса чтобы порт применился
    Restart-Service -Name TermService -Force -ErrorAction Stop

    Change "RDP enabled on port $RdpPort"
}


Log "FamilyTeam Windows RDP port configuration script" -Color Green
Log "Debug mode: $(("disabled", "enabled")[$DebugMode])"

Process-RDP

Log "Completed" -Color Green
