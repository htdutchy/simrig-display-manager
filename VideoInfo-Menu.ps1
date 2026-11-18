# Simrig Display Manager
# Local, interactive profile switcher for VideoInfo (AMD Eyefinity / NVIDIA Surround).
# Keep this script, Run-VideoInfo.cmd and VideoInfo.exe in the same directory.

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$videoInfo = Join-Path $root 'VideoInfo.exe'
$useOldEyefinity = $true   # AMD only. Use with profiles created via EyefinityPro.exe.
$loadDelayMs = 500         # Delay between operations within VideoInfo load.
$transitionPauseMs = 3000 # Time for the extended layout to settle before the next step.
$verifyAttempts = 4
$verifyIntervalMs = 1000
$exitDelaySeconds = 5      # Keep the result visible after a successful switch.

# Filenames intentionally preserve compatibility with the original AMD script.
# NVIDIA uses sim-surround.cfg for the third profile.
$profiles = @{
    '1' = @{ Name = 'Desk only';    File = 'desk.cfg' }
    '2' = @{ Name = 'Sim extended'; File = 'sim-extended.cfg' }
    '3' = @{ Name = 'Sim grouped';  File = 'sim-grouped.cfg' }
}
$script:gpuVendor = 'Unknown'

function Get-DisplayVendor {
    param([object]$Config)
    $amd = ($null -ne $Config.AMDConfig -and [bool]$Config.AMDConfig.IsInUse)
    $nvidia = ($null -ne $Config.NVIDIAConfig -and [bool]$Config.NVIDIAConfig.IsInUse)
    if ($amd -and $nvidia) { return 'Multiple' }
    if ($amd) { return 'AMD' }
    if ($nvidia) { return 'NVIDIA' }
    return 'Unsupported'
}

function Set-VendorProfiles {
    switch ($script:gpuVendor) {
        'AMD' {
            $profiles['3'].Name = 'Sim Eyefinity'
            $profiles['3'].File = 'sim-eyefinity.cfg'
        }
        'NVIDIA' {
            $profiles['3'].Name = 'Sim Surround'
            $profiles['3'].File = 'sim-surround.cfg'
        }
        default {
            $profiles['3'].Name = 'Sim grouped'
            $profiles['3'].File = 'sim-grouped.cfg'
        }
    }
}

function Pause-ForMenu {
    [void](Read-Host 'Press Enter to continue')
}

function Confirm-Dialog {
    param([string]$Title, [string]$Message)
    $answer = [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    )
    return ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Get-ProfilePath {
    param([string]$Number)
    $profile = $profiles[$Number]
    return (Join-Path -Path $root -ChildPath $profile.File)
}

# VideoInfo 2.1.3 may report NOT equal for byte-identical .cfg files.
# Match the actual layout instead; ignore non-topology settings like gamma,
# FreeSync, colour and refresh rate. This is not a complete settings comparison.
function Read-ProfileConfig {
    param([string]$Path)
    $json = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    return (ConvertFrom-Json -InputObject $json -ErrorAction Stop)
}

function Get-TopologySignature {
    param([object]$Config)

    if ($null -eq $Config -or $null -eq $Config.WindowsConfig) {
        throw 'Configuration is missing the WindowsConfig section.'
    }
    $vendor = Get-DisplayVendor -Config $Config
    if ($vendor -notin @('AMD', 'NVIDIA')) {
        throw "Unsupported graphics configuration: $vendor. An individual AMD or NVIDIA GPU is required."
    }
    $windows = $Config.WindowsConfig

    # GDI captures active desktop rectangles, positions and primary status.
    # Do not compare volatile adapter GUIDs, screen numbers or refresh rates.
    $activeRows = @()
    if ($null -ne $windows.GdiDisplaySettings) {
        foreach ($entry in $windows.GdiDisplaySettings.PSObject.Properties) {
            $screen = $entry.Value
            if ($null -eq $screen -or -not $screen.IsEnabled) { continue }
            $mode = $screen.DeviceMode
            $activeRows += ('{0}x{1}@{2},{3};primary={4}' -f
                $mode.PixelsWidth, $mode.PixelsHeight,
                $mode.Position.X, $mode.Position.Y, [bool]$screen.IsPrimary)
        }
    }

    $parts = @(
        ('GPU.Vendor={0}' -f $vendor)
        ('Windows.IsCloned={0}' -f [bool]$windows.IsCloned)
        ('Windows.PathCount={0}' -f @($windows.DisplayConfigPaths).Count)
        ('Windows.ActiveScreens={0}' -f (($activeRows | Sort-Object) -join '|'))
    )

    if ($vendor -eq 'AMD') {
        $amd = $Config.AMDConfig
        # The AMD desktops contain physical display IDs. Keep the working
        # v3 logic, including IDs for identical-model sim monitors.
        $desktopRows = @()
        foreach ($desktop in @($amd.Desktops)) {
            if ($null -eq $desktop) { continue }
            $ids = @($desktop.Displays | Where-Object { $null -ne $_ } | ForEach-Object {
                [string]$_.UniqueID
            } | Sort-Object)
            $desktopRows += ('type={0};size={1}x{2};pos={3},{4};monitors={5}' -f
                $desktop.Type, $desktop.SizeWidth, $desktop.SizeHeight,
                $desktop.TopLeftX, $desktop.TopLeftY, ($ids -join ','))
        }
        $eyefinity = $amd.EyefinityDesktop
        $parts += @(
            ('AMD.IsEyefinity={0}' -f [bool]$amd.IsEyefinity)
            ('AMD.IsCloned={0}' -f [bool]$amd.IsCloned)
            ('AMD.ADL2SLS={0}' -f [bool]$amd.Adl2SlsConfig.IsSlsEnabled)
            ('AMD.Grid={0}x{1}' -f $eyefinity.Rows, $eyefinity.Columns)
            ('AMD.Desktops={0}' -f (($desktopRows | Sort-Object) -join '|'))
        )
    }
    else {
        $nvidia = $Config.NVIDIAConfig
        # Surround/Mosaic is not just another extended Windows desktop.
        # Include NVIDIA-specific state so the grouped and independent
        # profiles cannot match solely on display geometry.
        $parts += @(
            ('NVIDIA.IsCloned={0}' -f [bool]$nvidia.IsCloned)
            ('NVIDIA.MosaicEnabled={0}' -f [bool]$nvidia.MosaicConfig.IsMosaicEnabled)
        )
        # Windows paths provide active monitor identities in either mode.
        # Do not compare source display numbers, which may be renumbered.
        $targetPaths = @()
        if ($null -ne $windows.DisplaySources) {
            foreach ($entry in $windows.DisplaySources.PSObject.Properties) {
                foreach ($target in @($entry.Value)) {
                    if ($null -ne $target -and $target.DevicePath) {
                        $targetPaths += [string]$target.DevicePath
                    }
                }
            }
        }
        $parts += ('Windows.TargetPaths={0}' -f (($targetPaths | Sort-Object) -join '|'))
    }
    return ($parts -join "`n")
}

function Get-SavedTopologySignature {
    param([string]$Number)
    $path = Get-ProfilePath $Number
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $config = Read-ProfileConfig -Path $path
    return (Get-TopologySignature -Config $config)
}

function Get-CurrentVideoConfig {
    # Capture once via VideoInfo save; this does not change active displays.
    $temp = Join-Path $root ('.topology-' + [Guid]::NewGuid().ToString('N') + '.cfg')
    try {
        & $videoInfo save $temp 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temp -PathType Leaf)) {
            throw 'VideoInfo could not save a temporary topology snapshot.'
        }
        return (Read-ProfileConfig -Path $temp)
    }
    finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-CurrentTopologySignature {
    return (Get-TopologySignature -Config (Get-CurrentVideoConfig))
}

function Get-ActiveProfile {
    try {
        $live = Get-CurrentTopologySignature
        $matching = @()
        foreach ($number in @('1', '2', '3')) {
            $saved = Get-SavedTopologySignature -Number $number
            if ($null -ne $saved -and $live -ceq $saved) { $matching += $number }
        }
        if ($matching.Count -eq 1) { return $matching[0] }
    }
    catch {
        Write-Host ("Topology detection failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
    # No match, or multiple indistinguishable profiles: avoid guessing.
    return $null
}

function Wait-ForProfileMatch {
    param([string]$Number)
    $expected = Get-SavedTopologySignature -Number $Number
    if ($null -eq $expected) { return $false }
    for ($attempt = 1; $attempt -le $verifyAttempts; $attempt++) {
        Start-Sleep -Milliseconds $verifyIntervalMs
        try {
            $live = Get-CurrentTopologySignature
            if ($live -ceq $expected) { return $true }
        }
        catch {
            Write-Host ("Topology verification attempt {0} failed: {1}" -f $attempt, $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    return $false
}

function Show-TopologyDiagnostics {
    Clear-Host
    Write-Host 'LIVE DISPLAY TOPOLOGY DIAGNOSTICS'
    Write-Host '================================='
    try {
        $live = Get-CurrentTopologySignature
        Write-Host "`nCurrent:" -ForegroundColor Cyan
        Write-Host $live
        foreach ($number in @('1', '2', '3')) {
            Write-Host ("`nSaved profile {0} ({1}):" -f $number, $profiles[$number].Name) -ForegroundColor Cyan
            $saved = Get-SavedTopologySignature -Number $number
            if ($null -eq $saved) {
                Write-Host 'Not saved.'
            }
            else {
                Write-Host $saved
                if ($live -ceq $saved) { Write-Host 'MATCH' -ForegroundColor Green }
                else { Write-Host 'DIFFERENT' -ForegroundColor Yellow }
            }
        }
    }
    catch {
        Write-Host ("Diagnostics failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    Write-Host "`nNo display settings were changed."
    Pause-ForMenu
}

function Show-Menu {
    Clear-Host
    Write-Host '=============================================='
    Write-Host '            SIMRIG DISPLAY MANAGER            '
    Write-Host '=============================================='
    Write-Host ''
    Write-Host 'Detecting current display configuration...'
    $current = Get-ActiveProfile
    Clear-Host
    Write-Host '=============================================='
    Write-Host '            SIMRIG DISPLAY MANAGER            '
    Write-Host '=============================================='
    Write-Host ''
    foreach ($number in @('1', '2', '3')) {
        $profile = $profiles[$number]
        $path = Get-ProfilePath $number
        $status = if (Test-Path -LiteralPath $path -PathType Leaf) { 'saved' } else { 'not saved yet' }
        if ($current -eq $number) { $status += ', ACTIVE' }
        Write-Host (' {0}. {1} [{2}]' -f $number, $profile.Name, $status)
    }
    Write-Host ''
    $currentText = if ($null -ne $current) { $profiles[$current].Name } else { 'Unknown (no saved topology match)' }
    Write-Host (' Current mode: {0}' -f $currentText)
    Write-Host ''
    Write-Host ' 8. Display topology diagnostics'
    Write-Host ' 9. Save current display configuration'
    Write-Host ' 0. Exit'
    Write-Host ''
    Write-Host ' Desk <-> grouped mode routes through Sim extended.'
    Write-Host (' Detected GPU: {0}' -f $script:gpuVendor)
    if ($script:gpuVendor -eq 'AMD') {
        Write-Host (' AMD Eyefinity API: {0}' -f $(if ($useOldEyefinity) { 'ADL2 (--oldEyefinity)' } else { 'ADLX (default)' }))
    }
    Write-Host ''
    return $current
}

function Save-Profile {
    param([string]$Number)

    $profile = $profiles[$Number]
    $destination = Get-ProfilePath $Number
    $exists = Test-Path -LiteralPath $destination -PathType Leaf

    $message = "Save the CURRENT display layout as:`n`n$($profile.Name)`n`n" +
        'Configure the layout with Windows and the GPU vendor control panel before saving.'
    if (-not (Confirm-Dialog 'Confirm display capture' $message)) {
        Write-Host 'Save cancelled.'
        return
    }

    if ($exists) {
        $message = "The profile '$($profile.Name)' already exists.`n`n" +
            'Overwrite it? A timestamped backup will be kept in the backups folder.'
        if (-not (Confirm-Dialog 'Confirm overwrite' $message)) {
            Write-Host 'Overwrite cancelled.'
            return
        }
    }

    $tempName = '{0}.pending-{1}.cfg' -f [IO.Path]::GetFileNameWithoutExtension($profile.File), [Guid]::NewGuid().ToString('N')
    $temp = Join-Path $root $tempName
    try {
        Write-Host ("`nCapturing current display settings for {0}...`n" -f $profile.Name)
        & $videoInfo save $temp
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) { throw "VideoInfo save exited with code $exitCode." }
        if (-not (Test-Path -LiteralPath $temp -PathType Leaf)) { throw 'VideoInfo did not create a configuration file.' }
        if ((Get-Item -LiteralPath $temp).Length -eq 0) { throw 'VideoInfo created an empty configuration file.' }

        if ($exists) {
            $backupDir = Join-Path $root 'backups'
            [void](New-Item -ItemType Directory -Path $backupDir -Force)
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
            $backupName = '{0}.{1}.bak' -f $profile.File, $stamp
            Copy-Item -LiteralPath $destination -Destination (Join-Path $backupDir $backupName) -ErrorAction Stop
            Write-Host ("Previous profile backed up as: backups\{0}" -f $backupName)
        }

        Copy-Item -LiteralPath $temp -Destination $destination -Force -ErrorAction Stop
        Write-Host ("`nSaved: {0}" -f $destination)
    }
    catch {
        Write-Host ("`nSAVE FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-ProfileStep {
    param([string]$Number, [bool]$Intermediate)

    $profile = $profiles[$Number]
    $path = Get-ProfilePath $Number
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing profile '$($profile.Name)' ($path). Save it using option 9 first."
    }

    $savedVendor = Get-DisplayVendor -Config (Read-ProfileConfig -Path $path)
    if ($savedVendor -ne $script:gpuVendor) {
        throw "Profile GPU vendor ($savedVendor) does not match the active GPU ($script:gpuVendor)."
    }

    Write-Host ("`nApplying: {0}" -f $profile.Name) -ForegroundColor Cyan
    $arguments = @('load', $path, "--delay:$loadDelayMs")
    if ($script:gpuVendor -eq 'AMD' -and $useOldEyefinity) { $arguments += '--oldEyefinity' }
    & $videoInfo @arguments
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "VideoInfo load exited with code $code for $($profile.Name)." }

    if (Wait-ForProfileMatch -Number $Number) {
        Write-Host ('Verified: {0}' -f $profile.Name) -ForegroundColor Green
        return $true
    }

    if ($Intermediate) {
        # Never apply the final config unless we can verify that Extended is active.
        throw "Could not verify that '$($profile.Name)' is active. Final switch cancelled. Check the physical layout and VideoInfo logs."
    }

    Write-Host ('WARNING: VideoInfo returned successfully but could not confirm the final {0} layout.' -f $profile.Name) -ForegroundColor Yellow
    Write-Host 'Please verify the physical displays. No further changes will be attempted.'
    return $false
}

function Load-Profile {
    param([string]$Number, [AllowNull()][string]$Current)

    $target = $profiles[$Number]
    $targetPath = Get-ProfilePath $Number
    if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
        Write-Host ("`nNo saved profile for {0}. Use option 9 first." -f $target.Name) -ForegroundColor Yellow
        Pause-ForMenu
        return $false
    }

    if ($Current -eq $Number) {
        Write-Host ("`n{0} is already active. No changes needed." -f $target.Name)
        Write-Host ("Closing in {0} seconds..." -f $exitDelaySeconds)
        Start-Sleep -Seconds $exitDelaySeconds
        return $true
    }

    # Known direct transitions with Extended are safe.
    # If source is unknown, a Desk/Eyefinity target also routes through Extended.
    $needsIntermediate = ($Number -in @('1', '3')) -and ($Current -notin @('2', $Number))
    $route = if ($needsIntermediate) { @('2', $Number) } else { @($Number) }

    if ($needsIntermediate -and -not (Test-Path -LiteralPath (Get-ProfilePath '2') -PathType Leaf)) {
        Write-Host "`nSim Extended profile is missing, and is required for safe switching." -ForegroundColor Red
        Write-Host 'Save it with option 9 -> 2 first.'
        Pause-ForMenu
        return $false
    }

    $sourceName = if ($null -ne $Current) { $profiles[$Current].Name } else { 'Unknown' }
    $routeNames = ($route | ForEach-Object { $profiles[$_].Name }) -join ' -> '
    Write-Host ("`nCurrent: {0}" -f $sourceName)
    Write-Host ("Route:   {0}" -f $routeNames)
    try {
        for ($index = 0; $index -lt $route.Count; $index++) {
            $step = $route[$index]
            $intermediate = ($index -lt ($route.Count - 1))
            $verified = Invoke-ProfileStep -Number $step -Intermediate $intermediate
            if ($intermediate) {
                Write-Host ("`nLetting the extended display layout settle for {0}ms..." -f $transitionPauseMs)
                Start-Sleep -Milliseconds $transitionPauseMs
            }
            elseif (-not $verified) {
                # Leave the window open so the user can see the verification warning.
                Pause-ForMenu
                return $false
            }
        }
        Write-Host "`nSwitch completed. Closing menu."
        Write-Host ("Closing in {0} seconds..." -f $exitDelaySeconds)
        Start-Sleep -Seconds $exitDelaySeconds
        return $true
    }
    catch {
        Write-Host ("`nSWITCH STOPPED: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Pause-ForMenu
        return $false
    }
}

if (-not (Test-Path -LiteralPath $videoInfo -PathType Leaf)) {
    Write-Host "Cannot find VideoInfo.exe at: $videoInfo" -ForegroundColor Red
    Write-Host 'Place VideoInfo.exe and VideoInfo-Menu.ps1 in your home VideoInfo folder.'
    Pause-ForMenu
    exit 1
}

try {
    Add-Type -AssemblyName System.Windows.Forms
    Set-Location -LiteralPath $root
    $Host.UI.RawUI.WindowTitle = 'Simrig Display Manager'
}
catch {
    Write-Host "Could not initialize menu: $($_.Exception.Message)" -ForegroundColor Red
    Pause-ForMenu
    exit 1
}

try {
    Write-Host 'Detecting graphics vendor...'
    $liveConfig = Get-CurrentVideoConfig
    $script:gpuVendor = Get-DisplayVendor -Config $liveConfig
    if ($script:gpuVendor -notin @('AMD', 'NVIDIA')) {
        throw "Detected '$($script:gpuVendor)' graphics configuration. This version supports one active AMD or NVIDIA GPU."
    }
    Set-VendorProfiles
}
catch {
    Write-Host ("GPU detection failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Pause-ForMenu
    exit 1
}

while ($true) {
    $current = Show-Menu
    $selection = (Read-Host 'Select').Trim()
    if ($selection -in @('1', '2', '3')) {
        if (Load-Profile -Number $selection -Current $current) { exit 0 }
    }
    elseif ($selection -eq '8') {
        Show-TopologyDiagnostics
    }
    elseif ($selection -eq '9') {
        while ($true) {
            Clear-Host
            Write-Host 'SAVE CURRENT DISPLAY CONFIGURATION'
            Write-Host ''
            Write-Host 'Configure the layout in Windows / your GPU control panel BEFORE saving.'
            Write-Host ''
            foreach ($number in @('1', '2', '3')) {
                Write-Host (' {0}. Save as {1}' -f $number, $profiles[$number].Name)
            }
            Write-Host ' 0. Return to main menu'
            Write-Host ''
            $saveSelection = (Read-Host 'Select profile to save').Trim()
            if ($saveSelection -eq '0') { break }
            if ($saveSelection -in @('1', '2', '3')) {
                Save-Profile -Number $saveSelection
                Pause-ForMenu
                break
            }
        }
    }
    elseif ($selection -eq '0') {
        exit 0
    }
}
