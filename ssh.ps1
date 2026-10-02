#Requires -RunAsAdministrator

# ============================================================
# OpenSSH Server Automatic Setup
# ============================================================

$ErrorActionPreference = "Stop"

# ============================================================
# SOUND SETTINGS
# ============================================================

$SoundEnabled = $true

# Success sound sequence
$SuccessSounds = @(
    @{ Frequency = 800;  Duration = 150 },
    @{ Frequency = 1200; Duration = 150 },
    @{ Frequency = 1600; Duration = 400 }
)

# Error sound
$ErrorSounds = @(
    @{ Frequency = 300; Duration = 800 }
)

function Play-Sounds {
    param (
        [array]$Sounds
    )

    if (-not $SoundEnabled) {
        return
    }

    foreach ($sound in $Sounds) {
        try {
            [Console]::Beep(
                $sound.Frequency,
                $sound.Duration
            )

            Start-Sleep -Milliseconds 75
        }
        catch {
            # Ignore sound errors; they should not stop installation
        }
    }
}

# ============================================================
# ERROR HANDLING
# ============================================================

trap {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Red
    Write-Host " INSTALLATION FAILED" -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red
    Write-Host ""
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""

    Play-Sounds $ErrorSounds

    Read-Host "Press Enter to exit"
    exit 1
}

# ============================================================
# START
# ============================================================

Clear-Host

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "     OpenSSH Server Automatic Setup" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# 1. SET NETWORK PROFILE TO PRIVATE
# ============================================================

Write-Host "[1/7] Setting network profile to Private..." -ForegroundColor Yellow

$profiles = Get-NetConnectionProfile

foreach ($profile in $profiles) {

    if ($profile.NetworkCategory -ne "Private") {

        Write-Host "  Changing '$($profile.Name)' to Private..."

        Set-NetConnectionProfile `
            -InterfaceIndex $profile.InterfaceIndex `
            -NetworkCategory Private
    }
    else {
        Write-Host "  '$($profile.Name)' is already Private."
    }
}

Write-Host "  Done." -ForegroundColor Green

# ============================================================
# 2. INSTALL OPENSSH SERVER
# ============================================================

Write-Host ""
Write-Host "[2/7] Installing OpenSSH Server..." -ForegroundColor Yellow

$OpenSSHCapability = Get-WindowsCapability -Online |
    Where-Object {
        $_.Name -like "OpenSSH.Server*"
    }

if (-not $OpenSSHCapability) {
    throw "OpenSSH Server capability could not be found."
}

if ($OpenSSHCapability.State -ne "Installed") {

    Write-Host "  Installing $($OpenSSHCapability.Name)..."

    Add-WindowsCapability `
        -Online `
        -Name $OpenSSHCapability.Name
}
else {
    Write-Host "  OpenSSH Server is already installed."
}

Write-Host "  Done." -ForegroundColor Green

# ============================================================
# 3. CONFIGURE SSHD
# ============================================================

Write-Host ""
Write-Host "[3/7] Configuring sshd..." -ForegroundColor Yellow

$SSHConfig = "$env:ProgramData\ssh\sshd_config"
$SSHExecutable = "$env:WINDIR\System32\OpenSSH\sshd.exe"

if (-not (Test-Path $SSHConfig)) {
    throw "sshd_config was not found at $SSHConfig"
}

if (-not (Test-Path $SSHExecutable)) {
    throw "sshd.exe was not found at $SSHExecutable"
}

# Create backup
$BackupConfig = "$SSHConfig.backup"

Copy-Item `
    -Path $SSHConfig `
    -Destination $BackupConfig `
    -Force

Write-Host "  Configuration backup:"
Write-Host "  $BackupConfig"

# Read configuration
$Config = Get-Content $SSHConfig -Raw

function Set-SSHOption {
    param (
        [string]$Name,
        [string]$Value
    )

    $script:Config = $script:Config.TrimEnd()

    $Pattern = "(?m)^\s*#?\s*" +
               [regex]::Escape($Name) +
               "\s+.*$"

    $Replacement = "$Name $Value"

    if ($script:Config -match $Pattern) {

        $script:Config = [regex]::Replace(
            $script:Config,
            $Pattern,
            $Replacement
        )
    }
    else {

        $script:Config += "`r`n$Replacement`r`n"
    }
}

# SSH settings
Set-SSHOption "Port" "22"

Set-SSHOption "PasswordAuthentication" "yes"

Set-SSHOption "PermitEmptyPasswords" "yes"

Set-SSHOption "PubkeyAuthentication" "yes"

# Write configuration
Set-Content `
    -Path $SSHConfig `
    -Value $Config `
    -Encoding ASCII

Write-Host "  SSH configuration updated."
Write-Host "  Done." -ForegroundColor Green

# ============================================================
# 4. ALLOW EMPTY WINDOWS PASSWORDS
# ============================================================

Write-Host ""
Write-Host "[4/7] Configuring Windows empty-password policy..." -ForegroundColor Yellow

$LSAPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"

New-ItemProperty `
    -Path $LSAPath `
    -Name "LimitBlankPasswordUse" `
    -PropertyType DWord `
    -Value 0 `
    -Force | Out-Null

Write-Host "  Blank-password network logons enabled."
Write-Host "  Done." -ForegroundColor Green

# ============================================================
# 5. CONFIGURE FIREWALL
# ============================================================

Write-Host ""
Write-Host "[5/7] Configuring Windows Firewall..." -ForegroundColor Yellow

$FirewallRuleName = "OpenSSH Server TCP 22"

# Remove an existing rule with our name
Get-NetFirewallRule `
    -DisplayName $FirewallRuleName `
    -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule `
    -ErrorAction SilentlyContinue

# Create firewall rule
New-NetFirewallRule `
    -DisplayName $FirewallRuleName `
    -Description "Allow inbound SSH connections on TCP port 22" `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort 22 `
    -Action Allow `
    -Profile Private |
    Out-Null

Write-Host "  TCP port 22 allowed on Private networks."
Write-Host "  Done." -ForegroundColor Green

# ============================================================
# 6. CONFIGURE AND START SSHD
# ============================================================

Write-Host ""
Write-Host "[6/7] Configuring OpenSSH service..." -ForegroundColor Yellow

# Set automatic startup
Set-Service `
    -Name "sshd" `
    -StartupType Automatic

Write-Host "  sshd startup set to Automatic."

# Validate configuration BEFORE starting service
Write-Host "  Validating sshd configuration..."

& $SSHExecutable -t

if ($LASTEXITCODE -ne 0) {
    throw "sshd configuration validation failed."
}

Write-Host "  Configuration is valid."

# Stop service if already running
$SSHService = Get-Service `
    -Name "sshd" `
    -ErrorAction Stop

if ($SSHService.Status -eq "Running") {

    Write-Host "  Restarting sshd..."

    Restart-Service "sshd"
}
else {

    Write-Host "  Starting sshd..."

    Start-Service "sshd"
}

# Verify service
Start-Sleep -Milliseconds 500

$SSHService = Get-Service "sshd"

if ($SSHService.Status -ne "Running") {
    throw "sshd service failed to start."
}

Write-Host "  sshd is running."
Write-Host "  Done." -ForegroundColor Green

# ============================================================
# 7. FINAL VALIDATION
# ============================================================

Write-Host ""
Write-Host "[7/7] Performing final validation..." -ForegroundColor Yellow

# Check port 22
$Listening = Get-NetTCPConnection `
    -LocalPort 22 `
    -State Listen `
    -ErrorAction SilentlyContinue

if (-not $Listening) {
    throw "Nothing is listening on TCP port 22."
}

# Check firewall rule
$Firewall = Get-NetFirewallRule `
    -DisplayName $FirewallRuleName `
    -ErrorAction SilentlyContinue

if (-not $Firewall) {
    throw "SSH firewall rule was not found."
}

Write-Host "  SSH is listening on TCP port 22."
Write-Host "  Firewall rule exists."
Write-Host "  sshd service is running."
Write-Host "  Done." -ForegroundColor Green

# ============================================================
# SUCCESS
# ============================================================

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "       INSTALLATION COMPLETE" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""

Write-Host "OpenSSH Server:       Installed"
Write-Host "SSH Service:          Running"
Write-Host "Startup:              Automatic"
Write-Host "SSH Port:             22"
Write-Host "Password Login:       Enabled"
Write-Host "Empty Passwords:      Enabled"
Write-Host "Public Key Login:     Enabled"
Write-Host "Firewall:             TCP 22 allowed"
Write-Host "Network Profile:      Private"
Write-Host ""

# Display IP addresses
Write-Host "IP addresses:" -ForegroundColor Cyan

Get-NetIPAddress `
    -AddressFamily IPv4 `
    -ErrorAction SilentlyContinue |
    Where-Object {
        $_.IPAddress -notlike "127.*" -and
        $_.IPAddress -notlike "169.254.*"
    } |
    ForEach-Object {
        Write-Host "  $($_.IPAddress)"
    }

Write-Host ""
Write-Host "You can connect using:" -ForegroundColor Cyan
Write-Host ""
Write-Host "    ssh USERNAME@IP_ADDRESS"
Write-Host ""

# ============================================================
# SUCCESS SOUND
# ============================================================

Play-Sounds $SuccessSounds

Write-Host ""
Read-Host "Press Enter to exit"
