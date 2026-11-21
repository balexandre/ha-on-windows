<#
.SYNOPSIS
    Start, stop and manage Home Assistant in Docker Desktop.

.DESCRIPTION
    Commands:
      start    Create (first time) or start Home Assistant, then open it in the browser
      stop     Stop Home Assistant
      restart  Stop and start again
      status   Show whether it's running and the addresses to open it
      logs     Follow the log (Ctrl+C to stop watching)
      update   Download the newest version and recreate the container (settings are kept)
      remove   Delete the container (settings are kept)
      open     Open Home Assistant in the browser

.EXAMPLE
    .\ha.ps1 start
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('start', 'stop', 'restart', 'status', 'logs', 'update', 'remove', 'open')]
    [string]$Command = 'status'
)

# --- Settings you may want to change ------------------------------------
$TimeZone  = 'Europe/Copenhagen'   # e.g. Europe/Lisbon, Europe/London
$Port      = 8123
$ConfigDir = Join-Path $env:USERPROFILE 'HomeAssistant\config'
# -------------------------------------------------------------------------

$Name  = 'homeassistant'
$Image = 'ghcr.io/home-assistant/home-assistant:stable'
$Url   = "http://localhost:$Port"

function Write-Info($Text) { Write-Host $Text -ForegroundColor Cyan }
function Write-Ok($Text)   { Write-Host $Text -ForegroundColor Green }
function Write-Warn($Text) { Write-Host $Text -ForegroundColor Yellow }

function Stop-WithError($Text) {
    Write-Host $Text -ForegroundColor Red
    exit 1
}

# Make sure Docker Desktop is installed and running; start it if needed.
function Assert-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Stop-WithError "Docker isn't installed (or this PowerShell window was opened before installing it). Install Docker Desktop, then open a new PowerShell window."
    }
    docker info *> $null
    if ($LASTEXITCODE -eq 0) { return }

    $desktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    if (-not (Test-Path $desktop)) {
        Stop-WithError "Docker Desktop isn't running. Start it from the Start menu, wait for 'Engine running', then try again."
    }
    Write-Info "Starting Docker Desktop (this can take a minute)..."
    Start-Process $desktop
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 3
        docker info *> $null
        if ($LASTEXITCODE -eq 0) { Write-Ok "Docker is ready."; return }
        Write-Host "." -NoNewline
    }
    Write-Host ""
    Stop-WithError "Docker Desktop didn't become ready in 3 minutes. Open it and check for errors."
}

# Returns 'running', 'exited', 'created', ... or 'missing' if the container doesn't exist.
function Get-State {
    $state = docker container inspect -f '{{.State.Status}}' $Name 2> $null
    if ($LASTEXITCODE -ne 0 -or -not $state) { return 'missing' }
    return "$state".Trim()
}

function Get-LanAddress {
    $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixOrigin -eq 'Dhcp' } |
        Select-Object -First 1 -ExpandProperty IPAddress
    if ($ip) { return "http://${ip}:$Port" }
    return $null
}

function Wait-Ready {
    Write-Info "Waiting for Home Assistant to answer (first start can take a few minutes)..."
    for ($i = 0; $i -lt 90; $i++) {
        try {
            $null = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3
            Write-Host ""
            return $true
        } catch {
            Write-Host "." -NoNewline
            Start-Sleep -Seconds 2
        }
    }
    Write-Host ""
    return $false
}

function Show-Addresses {
    Write-Host "  On this PC:   $Url"
    $lan = Get-LanAddress
    if ($lan) { Write-Host "  On your phone: $lan  (same Wi-Fi)" }
}

function Start-HA {
    $state = Get-State
    if ($state -eq 'running') {
        Write-Ok "Home Assistant is already running."
        Show-Addresses
        return
    }

    if ($state -eq 'missing') {
        Write-Info "Creating Home Assistant (settings folder: $ConfigDir)..."
        New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
        docker run -d `
            --name $Name `
            --restart=unless-stopped `
            -e "TZ=$TimeZone" `
            -v "${ConfigDir}:/config" `
            -p "${Port}:8123" `
            $Image | Out-Null
        if ($LASTEXITCODE -ne 0) { Stop-WithError "Couldn't create the container. See the message above." }
    } else {
        Write-Info "Starting Home Assistant..."
        docker start $Name | Out-Null
        if ($LASTEXITCODE -ne 0) { Stop-WithError "Couldn't start the container. See the message above." }
    }

    if (Wait-Ready) {
        Write-Ok "Home Assistant is running."
        Show-Addresses
        Start-Process $Url
    } else {
        Write-Warn "Home Assistant is starting but isn't answering yet. Try $Url in a few minutes, or run: .\ha.ps1 logs"
    }
}

function Stop-HA {
    if ((Get-State) -eq 'running') {
        Write-Info "Stopping Home Assistant..."
        docker stop $Name | Out-Null
        Write-Ok "Stopped."
    } else {
        Write-Host "Home Assistant isn't running."
    }
}

function Remove-HA {
    if ((Get-State) -eq 'missing') {
        Write-Host "There's no Home Assistant container to remove."
        return
    }
    docker rm -f $Name | Out-Null
    Write-Ok "Container removed. Your settings are still in $ConfigDir"
}

Assert-Docker

switch ($Command) {
    'start'   { Start-HA }
    'stop'    { Stop-HA }
    'restart' { Stop-HA; Start-HA }
    'status'  {
        $state = Get-State
        switch ($state) {
            'running' { Write-Ok "Home Assistant is running."; Show-Addresses }
            'missing' { Write-Host "Home Assistant isn't set up yet. Run: .\ha.ps1 start" }
            default   { Write-Warn "Home Assistant is stopped ($state). Run: .\ha.ps1 start" }
        }
    }
    'logs'    {
        if ((Get-State) -eq 'missing') { Stop-WithError "Home Assistant isn't set up yet. Run: .\ha.ps1 start" }
        Write-Info "Showing the log. Press Ctrl+C to stop watching (Home Assistant keeps running)."
        docker logs -f --tail 100 $Name
    }
    'update'  {
        Write-Info "Downloading the newest Home Assistant..."
        docker pull $Image
        if ($LASTEXITCODE -ne 0) { Stop-WithError "Download failed. Check your internet connection." }
        Remove-HA
        Start-HA
    }
    'remove'  { Remove-HA }
    'open'    { Start-Process $Url }
}
