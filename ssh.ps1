#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

# ============================================================
# CONFIGURATION
# ============================================================

$SSHPort = 22

# Empty passwords are VERY insecure.
$AllowEmptyPasswords = $true

# Sound
$SoundEnabled = $true

$SuccessSounds = @(
    @{ Frequency = 800;  Duration = 150 },
    @{ Frequency = 1200; Duration = 150 },
    @{ Frequency = 1600; Duration = 400 }
)

$ErrorSounds = @(
    @{ Frequency = 300; Duration = 800 }
)

# ============================================================
# SOUND FUNCTION
# ============================================================

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
            # Sound failure must not break installation
        }
    }
}

# ============================================================
# ERROR HANDLER
# ============================================================

trap {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Red
    Write-Host "          INSTALLATION FAILED" -ForegroundColor Red
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
Write-Host "       OpenSSH Server Automatic Setup" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# 1. NETWORK PROFILE
# ============================================================

Write-Host "[1/8] Setting network profile to Private..." -ForegroundColor Yellow

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
# 2. INSTALL OPENSSH
# ============================================================

Write-Host ""
Write-Host "[2/8] Installing OpenSSH Server..." -ForegroundColor Yellow

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
# 3. INITIALIZE SSHD
# ============================================================

Write-Host ""
Write-Host "[3/8] Initializing OpenSSH configuration..." -ForegroundColor Yellow

$SSHConfig = "$env:ProgramData\ssh\sshd_config"
$SSHExecutable = "$env:WINDIR\System32\OpenSSH\sshd.exe"

if (-not (Test-Path $SSHExecutable)) {
    throw "sshd.exe was not found at $SSHExecutable"
}

# Make sure the service exists
$SSHService = Get-Service -Name "sshd" -ErrorAction SilentlyContinue

if (-not $SSHService) {
    throw "The sshd Windows service was not found."
}

# Configure automatic startup
Set-Service `
    -Name "sshd" `
    -StartupType Automatic

# ------------------------------------------------------------
# Start sshd ONCE so Windows generates sshd_config
# ------------------------------------------------------------

if (-not (Test-Path $SSHConfig)) {

    Write-Host "  sshd_config does not exist yet."
    Write-Host "  Starting sshd to generate the default configuration..."

    Start-Service "sshd"

    # Give OpenSSH a moment to generate its files
    $timeout = 10
    $elapsed = 0

    while (-not (Test-Path $SSHConfig) -and $elapsed -lt $timeout) {

        Start-Sleep -Milliseconds 500
        $elapsed += 0.5
    }

    if (-not (Test-Path $SSHConfig)) {
        throw "sshd_config was not generated after starting sshd."
    }

    Write-Host "  sshd_config generated."
}
else {
    Write-Host "  sshd_config already exists."
}

# Stop service before modifying configuration
$SSHService = Get-Service "sshd"

if ($SSHService.Status -eq "Running") {

    Write-Host "  Stopping sshd for configuration..."

    Stop-Service "sshd" -Force

    $SSHService.WaitForStatus(
        [System.ServiceProcess.ServiceControllerStatus]::Stopped,
        [TimeSpan]::FromSeconds(10)
    )
}

Write-Host "  Done." -ForegroundColor Green

# ============================================================
# 4. CONFIGURE SSHD
# ============================================================

Write-Host ""
Write-Host "[4/8] Configuring sshd..." -ForegroundColor Yellow

if (-not (Test-Path $SSHConfig)) {
    throw "sshd_config still does not exist."
}

# Backup configuration
$BackupConfig = "$SSHConfig.backup"

Copy-Item `
    -Path $SSHConfig `
    -Destination $BackupConfig `
    -Force

Write-Host "  Backup created:"
Write-Host "  $BackupConfig"

# Read config
$Config = Get-Content `
    -Path $SSHConfig `
    -Raw

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

        $script:Config +=
            "`r`n$Replacement`r`n"
    }
}

# SSH port
Set-SSHOption "Port" "$SSHPort"

# Password authentication
Set-SSHOption "PasswordAuthentication" "yes"

# Public-key authentication
Set-SSHOption "PubkeyAuthentication" "yes"

# Empty passwords
if ($AllowEmptyPasswords) {
    Set-SSHOption "PermitEmptyPasswords" "yes"
}
else {
    Set-SSHOption "PermitEmptyPasswords" "no"
}

# Save
Set-Content `
    -Path $SSHConfig `
    -Value $Config `
    -Encoding ASCII

Write-Host "  SSH configuration updated."
Write-Host "  Done." -ForegroundColor Green

# ============================================================
# 5. WINDOWS EMPTY PASSWORD POLICY
# ============================================================

Write-Host ""
Write-Host "[5/8] Configuring Windows password policy..." -ForegroundColor Yellow

$LSAPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"

if ($AllowEmptyPasswords) {

    New-ItemProperty `
        -Path $LSAPath `
        -Name "LimitBlankPasswordUse" `
        -PropertyType DWord `
        -Value 0 `
        -Force |
        Out-Null

    Write-Host "  Empty-password network logons enabled."
}
else {

    New-ItemProperty `
        -Path $LSAPath `
        -Name "LimitBlankPasswordUse" `
        -PropertyType DWord `
        -Value 1 `
        -Force |
        Out-Null

    Write-Host "  Empty-password network logons disabled."
}

Write-Host "  Done." -ForegroundColor Green

# ============================================================
# 6. FIREWALL
# ============================================================

Write-Host ""
Write-Host "[6/8] Configuring Windows Firewall..." -ForegroundColor Yellow

$FirewallRuleName = "OpenSSH Server TCP $SSHPort"

# Remove our previous rule
Get-NetFirewallRule `
    -DisplayName $FirewallRuleName `
    -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule `
    -ErrorAction SilentlyContinue

# Create new rule
New-NetFirewallRule `
    -DisplayName $FirewallRuleName `
    -Description "Allow inbound OpenSSH connections" `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort $SSHPort `
    -Action Allow `
    -Profile Private |
    Out-Null

Write-Host "  TCP port $SSHPort allowed."
Write-Host "  Done." -ForegroundColor Green

# ============================================================
# 7. VALIDATE AND START SSHD
# ============================================================

Write-Host ""
Write-Host "[7/8] Validating and starting OpenSSH..." -ForegroundColor Yellow

Write-Host "  Validating sshd_config..."

& $SSHExecutable -t

if ($LASTEXITCODE -ne 0) {
    throw "sshd configuration validation failed."
}

Write-Host "  Configuration is valid."

# Start service
Start-Service "sshd"

Start-Sleep -Milliseconds 1000

$SSHService = Get-Service "sshd"

if ($SSHService.Status -ne "Running") {
    throw "sshd failed to start."
}

Write-Host "  sshd is running."

# ============================================================
# 8. FINAL VALIDATION
# ============================================================

Write-Host ""
Write-Host "[8/8] Performing final validation..." -ForegroundColor Yellow

# Check TCP listener
$Listening = Get-NetTCPConnection `
    -LocalPort $SSHPort `
    -State Listen `
    -ErrorAction SilentlyContinue

if (-not $Listening) {
    throw "Nothing is listening on TCP port $SSHPort."
}

# Check firewall
$Firewall = Get-NetFirewallRule `
    -DisplayName $FirewallRuleName `
    -ErrorAction SilentlyContinue

if (-not $Firewall) {
    throw "SSH firewall rule was not found."
}

# Check network profiles
$PrivateProfiles = Get-NetConnectionProfile |
    Where-Object {
        $_.NetworkCategory -eq "Private"
    }

if (-not $PrivateProfiles) {
    Write-Host "  WARNING: No Private network profile found."
}

Write-Host "  TCP port $SSHPort is listening."
Write-Host "  Firewall rule exists."
Write-Host "  sshd service is running."
Write-Host "  Done." -ForegroundColor Green

# ============================================================
# SUCCESS
# ============================================================

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "        INSTALLATION COMPLETE" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""

Write-Host "OpenSSH Server:       Installed"
Write-Host "SSH Service:          Running"
Write-Host "Startup:              Automatic"
Write-Host "SSH Port:             $SSHPort"
Write-Host "Password Login:       Enabled"
Write-Host "Empty Passwords:      $AllowEmptyPasswords"
Write-Host "Public Key Login:     Enabled"
Write-Host "Firewall:             TCP $SSHPort allowed"
Write-Host "Network Profile:      Private"
Write-Host ""

# ============================================================
# SHOW IP ADDRESSES
# ============================================================

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

# ============================================================
# SUCCESS SOUND
# ============================================================

Play-Sounds $SuccessSounds

Write-Host ""
Read-Host "Press Enter to exit"
