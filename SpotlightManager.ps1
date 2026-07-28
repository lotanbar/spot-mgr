param(
    [switch]$Silent,
    [switch]$Refresh,
    [switch]$ElevatedFix,
    [switch]$OpenLearnMore,
    [string]$ExportSource
)

# Set to $true only for the seconds-capable debug build (see build.ps1).
# Task Scheduler hard-rejects repetition intervals under 60 seconds, so when
# this is on and the user picks a sub-minute interval, the app falls back to
# an in-process timer instead of a real scheduled task. That timer only runs
# while this app instance stays open - it is a session-only debugging aid,
# not a replacement for the real auto-refresh mechanism.
$Script:IsDebugBuild = $false

# Base64 of a zip of the git repo (source + full history) this exe was built
# from. Filled in by build.ps1 at compile time - stays $null if you run the
# .ps1 directly. Not auto-extracted on startup (that would add overhead/
# clutter to every single launch, including the silent scheduled refresh and
# the Learn More shortcut); only written to disk if -ExportSource is passed.
$Script:EmbeddedRepoZipBase64 = $null

if ($ExportSource) {
    if (-not $Script:EmbeddedRepoZipBase64) {
        Write-Output "This build has no embedded source (run directly from the .ps1, or built without build.ps1)."
        exit 1
    }
    try {
        $bytes = [Convert]::FromBase64String($Script:EmbeddedRepoZipBase64)
        [System.IO.File]::WriteAllBytes($ExportSource, $bytes)
        Write-Output "Wrote embedded source (repo + git history) to $ExportSource"
    } catch {
        Write-Output "Failed to export embedded source: $($_.Exception.Message)"
        exit 1
    }
    exit 0
}

# ============================================================
# Spotlight Manager
# Fixes Windows Spotlight / Desktop Spotlight getting stuck on
# the same images, and provides a manual/interval-based image
# rotation that does not depend on Microsoft's own (unreliable)
# background sync service.
# ============================================================

$ErrorActionPreference = "Stop"

$AppDir      = "$env:LOCALAPPDATA\SpotlightManager"
$CacheDir    = "$AppDir\Cache"
$StatePath   = "$AppDir\state.json"
$LogPath     = "$AppDir\log.txt"
$TaskName    = "SpotlightManagerAutoRefresh"
$ApiBase     = "https://fd.api.iris.microsoft.com/v4/api/selection?&placement=88000820&bcnt={0}&country=US&locale=en-US&fmt=json"

New-Item -ItemType Directory -Path $CacheDir -Force -ErrorAction SilentlyContinue | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    try { Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue } catch {}
}

function Find-ChromeExecutable {
    # Checks the registered App Paths first (works regardless of install
    # location/user vs machine install), then falls back to the common
    # install folders, since different machines may have Chrome in
    # different places or not installed at all.
    foreach ($regPath in @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe"
    )) {
        try {
            $p = (Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue).'(default)'
            if ($p -and (Test-Path $p)) { return $p }
        } catch {}
    }
    foreach ($candidate in @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )) {
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

function Open-LearnMoreLink {
    param([string]$Url)
    if (-not $Url) { return }
    # Defensive strip in case an older cached entry still has the
    # microsoft-edge: deep-link scheme from a previous version.
    $cleanUrl = $Url -replace '^microsoft-edge:', ''
    try {
        $chrome = Find-ChromeExecutable
        if ($chrome) {
            Start-Process -FilePath $chrome -ArgumentList $cleanUrl
            Write-Log "Opened Learn More link in Chrome: $cleanUrl"
        } else {
            Write-Log "Chrome not found on this machine, opening Learn More link in the default browser instead."
            Start-Process $cleanUrl
        }
    } catch {
        Write-Log "Failed to open Learn More link: $($_.Exception.Message)"
    }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-InternetConnection {
    # Informational only - probes the actual Spotlight API host rather
    # than a generic connectivity-check endpoint, since networks that
    # block the latter can still reach the former just fine.
    try {
        $r = Invoke-WebRequest -Uri "https://fd.api.iris.microsoft.com" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        return $true
    } catch [System.Net.WebException] {
        # Any HTTP response (even an error status) proves connectivity.
        return $true
    } catch {
        return $false
    }
}

# -----------------------------------------------------------------
# State (list of cached image paths + current index)
# -----------------------------------------------------------------
function New-ImageEntry {
    param($Path, $Title = $null, $Description = $null, $Copyright = $null, $LearnMoreUrl = $null)
    return [PSCustomObject]@{
        Path         = $Path
        Title        = $Title
        Description  = $Description
        Copyright    = $Copyright
        LearnMoreUrl = $LearnMoreUrl
    }
}

function Get-State {
    if (Test-Path $StatePath) {
        try {
            $s = Get-Content $StatePath -Raw | ConvertFrom-Json
            $images = @()
            foreach ($item in @($s.Images)) {
                if ($item -is [string]) {
                    # Migrate from the older state format (plain path strings, no metadata).
                    $images += New-ImageEntry -Path $item
                } else {
                    $images += New-ImageEntry -Path $item.Path -Title $item.Title -Description $item.Description -Copyright $item.Copyright -LearnMoreUrl $item.LearnMoreUrl
                }
            }
            return [PSCustomObject]@{
                Images = $images
                Index  = [int]$s.Index
            }
        } catch {
            Write-Log "State file corrupt, resetting. $($_.Exception.Message)"
        }
    }
    return [PSCustomObject]@{ Images = @(); Index = -1 }
}

function Save-State($state) {
    try {
        $state | ConvertTo-Json | Set-Content -Path $StatePath -Encoding UTF8
    } catch {
        Write-Log "Failed to save state: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------
# Fetch fresh images from Microsoft's Spotlight API into our own
# user-writable cache (never touches protected system folders).
# -----------------------------------------------------------------
function Get-NewSpotlightImages {
    param([int]$Count = 4)

    $downloaded = @()
    try {
        $uri = [string]::Format($ApiBase, $Count)
        $resp = Invoke-RestMethod -Uri $uri -TimeoutSec 15
        $items = $resp.batchrsp.items
        if (-not $items -or $items.Count -eq 0) {
            Write-Log "Spotlight API returned no items."
            return @()
        }

        foreach ($it in $items) {
            try {
                $parsed = $it.item | ConvertFrom-Json
                $ad = $parsed.ad
                $url = $ad.landscapeImage.asset
                if (-not $url) { continue }

                $md5 = [System.Security.Cryptography.MD5]::Create()
                $hashBytes = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($url))
                $hash = ([BitConverter]::ToString($hashBytes) -replace '-', '').ToLower()
                $dest = Join-Path $CacheDir "$hash.jpg"

                if (-not (Test-Path $dest)) {
                    Invoke-WebRequest -Uri $url -OutFile $dest -TimeoutSec 30
                    Write-Log "Downloaded new image: $hash.jpg"
                }

                # ctaUri is a "microsoft-edge:https://www.bing.com/spotlight?..." deep link -
                # the microsoft-edge: scheme is stripped since we open it in Chrome instead.
                $learnMoreUrl = $ad.ctaUri -replace '^microsoft-edge:', ''
                $downloaded += New-ImageEntry -Path $dest -Title $ad.title -Description $ad.description -Copyright $ad.copyright -LearnMoreUrl $learnMoreUrl
            } catch {
                Write-Log "Failed to download one image: $($_.Exception.Message)"
            }
        }
    } catch {
        Write-Log "Spotlight API request failed: $($_.Exception.Message)"
    }
    return $downloaded
}

# -----------------------------------------------------------------
# Wallpaper setting via Win32 API - works without admin rights and
# does not depend on any Microsoft background service.
# -----------------------------------------------------------------
if (-not ([System.Management.Automation.PSTypeName]'Native.Wallpaper').Type) {
    Add-Type -Namespace Native -Name Wallpaper -MemberDefinition @"
[DllImport("user32.dll", CharSet=CharSet.Auto)]
public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
"@
}

function Set-DesktopWallpaper {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-Log "Cannot set wallpaper, file missing: $Path"
        return $false
    }
    try {
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name WallpaperStyle -Value "10" -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name TileWallpaper -Value "0" -ErrorAction SilentlyContinue
        $SPI_SETDESKWALLPAPER = 0x0014
        $SPIF_UPDATEINIFILE   = 0x01
        $SPIF_SENDCHANGE      = 0x02
        [Native.Wallpaper]::SystemParametersInfo($SPI_SETDESKWALLPAPER, 0, $Path, $SPIF_UPDATEINIFILE -bor $SPIF_SENDCHANGE) | Out-Null
        Write-Log "Wallpaper set to $Path"
        return $true
    } catch {
        Write-Log "Failed to set wallpaper: $($_.Exception.Message)"
        return $false
    }
}

# -----------------------------------------------------------------
# Diagnostics / one-time repair of the underlying Windows Spotlight
# bugs. Every step checks current state first and only changes
# what is actually wrong - safe to run repeatedly on any machine.
# -----------------------------------------------------------------
function Repair-ConsumerFeaturesPolicy {
    # HKLM policy that can silently disable Spotlight system-wide.
    # Requires admin. Only touched if present AND set to block.
    $path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
    try {
        if (-not (Test-Path $path)) {
            return "OK - CloudContent policy key does not exist, nothing to do."
        }
        $val = (Get-ItemProperty -Path $path -Name "DisableWindowsConsumerFeatures" -ErrorAction SilentlyContinue).DisableWindowsConsumerFeatures
        if ($null -eq $val) {
            return "OK - DisableWindowsConsumerFeatures not set."
        }
        if ($val -eq 0) {
            return "OK - DisableWindowsConsumerFeatures already 0 (not blocking)."
        }
        if (-not (Test-IsAdmin)) {
            return "SKIPPED - DisableWindowsConsumerFeatures=1 is blocking Spotlight, but admin rights are required to fix it."
        }
        Remove-ItemProperty -Path $path -Name "DisableWindowsConsumerFeatures" -ErrorAction Stop
        return "FIXED - Removed DisableWindowsConsumerFeatures policy that was blocking Spotlight."
    } catch {
        return "FAILED - Could not check/fix consumer features policy: $($_.Exception.Message)"
    }
}

function Repair-ContentDeliveryFlags {
    # Per-user flags that gate the lock screen Spotlight feed.
    $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
    $targets = @{
        "RotatingLockScreenEnabled"        = 1
        "RotatingLockScreenOverlayEnabled" = 1
        "SubscribedContent-338387Enabled"  = 1
    }
    try {
        if (-not (Test-Path $path)) {
            New-Item -Path $path -Force | Out-Null
        }
        $changed = @()
        foreach ($name in $targets.Keys) {
            $current = (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name
            if ($current -ne $targets[$name]) {
                Set-ItemProperty -Path $path -Name $name -Value $targets[$name] -Type DWord
                $changed += $name
            }
        }
        if ($changed.Count -eq 0) {
            return "OK - Lock screen Spotlight registry flags already correct."
        }
        return "FIXED - Enabled: $($changed -join ', ')"
    } catch {
        return "FAILED - Could not check/fix ContentDeliveryManager flags: $($_.Exception.Message)"
    }
}

function Repair-IrisServiceCache {
    # Known bug: the desktop Spotlight component (MicrosoftWindows.Client.CBS)
    # will not fetch any content unless this cache folder exists.
    try {
        $pkg = Get-AppxPackage -Name "MicrosoftWindows.Client.CBS" -ErrorAction SilentlyContinue
        if (-not $pkg) {
            return "OK - Desktop Spotlight component (MicrosoftWindows.Client.CBS) not present on this machine, nothing to do."
        }
        $irisPath = "$env:LOCALAPPDATA\Packages\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\LocalCache\Microsoft\IrisService"
        if (Test-Path $irisPath) {
            return "OK - IrisService cache folder already exists."
        }
        New-Item -ItemType Directory -Path $irisPath -Force -ErrorAction Stop | Out-Null
        return "FIXED - Created missing IrisService cache folder."
    } catch {
        return "FAILED - Could not check/fix IrisService cache folder: $($_.Exception.Message)"
    }
}

function Invoke-Diagnostics {
    param([scriptblock]$LogCallback)

    $results = @()
    $results += "Elevated: $(Test-IsAdmin)"
    $results += "Internet: $(Test-InternetConnection)"
    $results += "-- Consumer features policy --"
    $results += (Repair-ConsumerFeaturesPolicy)
    $results += "-- Lock screen Spotlight flags --"
    $results += (Repair-ContentDeliveryFlags)
    $results += "-- Desktop Spotlight cache bug --"
    $results += (Repair-IrisServiceCache)

    foreach ($r in $results) {
        Write-Log $r
        if ($LogCallback) { & $LogCallback $r }
    }
    return $results
}

# -----------------------------------------------------------------
# Scheduled task management for interval-based auto refresh
# -----------------------------------------------------------------
function Format-Interval {
    param([TimeSpan]$Interval)

    $parts = @()
    if ($Interval.Days -gt 0)    { $parts += "$($Interval.Days)d" }
    if ($Interval.Hours -gt 0)   { $parts += "$($Interval.Hours)h" }
    if ($Interval.Minutes -gt 0) { $parts += "$($Interval.Minutes)m" }
    if ($Interval.Seconds -gt 0) { $parts += "$($Interval.Seconds)s" }
    if ($parts.Count -eq 0) { return "0s" }
    return ($parts -join " ")
}

# -----------------------------------------------------------------
# Builds a self-contained refresh script (no dependency on this exe's
# file path surviving) and returns it as a base64 -EncodedCommand
# payload for powershell.exe. The functions are pulled from THIS
# process's already-loaded definitions (not re-typed/duplicated), so
# the standalone version can never drift out of sync with the real
# Get-NewSpotlightImages/Set-DesktopWallpaper/Move-SpotlightImage logic.
# -----------------------------------------------------------------
function Get-SilentRefreshEncodedCommand {
    $neededFunctions = @(
        "Write-Log", "New-ImageEntry", "Get-State", "Save-State",
        "Get-NewSpotlightImages", "Set-DesktopWallpaper", "Move-SpotlightImage"
    )

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('$ErrorActionPreference = "Stop"')
    [void]$sb.AppendLine("`$AppDir   = '$AppDir'")
    [void]$sb.AppendLine("`$CacheDir = '$CacheDir'")
    [void]$sb.AppendLine("`$StatePath = '$StatePath'")
    [void]$sb.AppendLine("`$LogPath  = '$LogPath'")
    [void]$sb.AppendLine("`$ApiBase  = '$ApiBase'")
    [void]$sb.AppendLine('New-Item -ItemType Directory -Path $CacheDir -Force -ErrorAction SilentlyContinue | Out-Null')
    [void]$sb.AppendLine(@'
if (-not ([System.Management.Automation.PSTypeName]'Native.Wallpaper').Type) {
    Add-Type -Namespace Native -Name Wallpaper -MemberDefinition @"
[DllImport("user32.dll", CharSet=CharSet.Auto)]
public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
"@
}
'@)

    foreach ($name in $neededFunctions) {
        $def = (Get-Command $name -CommandType Function).Definition
        [void]$sb.AppendLine("function $name {$def}")
    }
    [void]$sb.AppendLine('Move-SpotlightImage -Direction "Next" | Out-Null')

    $bytes = [System.Text.Encoding]::Unicode.GetBytes($sb.ToString())
    return [Convert]::ToBase64String($bytes)
}

# Task Scheduler's repetition trigger rejects any interval under 60 seconds
# (confirmed: registering with e.g. PT30S throws "value ... out of range"),
# so anything faster than that cannot go through Register-ScheduledTask at all.
#
# The action runs powershell.exe (a core Windows component) with the whole
# refresh logic passed as -EncodedCommand, instead of pointing at this exe's
# file path. That means the schedule keeps working in Windows even after
# this portable exe is deleted or moved - only %LOCALAPPDATA%\SpotlightManager
# (cache + state, already there regardless) needs to remain.
function Set-AutoRefreshSchedule {
    param([TimeSpan]$Interval)

    try {
        $psExe = Join-Path $env:windir "System32\WindowsPowerShell\v1.0\powershell.exe"
        $encoded = Get-SilentRefreshEncodedCommand
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

        $action = New-ScheduledTaskAction -Execute $psExe -Argument "-NoProfile -WindowStyle Hidden -EncodedCommand $encoded"
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval $Interval -RepetitionDuration (New-TimeSpan -Days 3650)
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description "Rotates the desktop Spotlight image on an interval. Self-contained - does not depend on SpotlightManager.exe still existing." | Out-Null
        Write-Log "Auto-refresh scheduled every $(Format-Interval $Interval) (self-contained, exe not required to persist)."
        return $true
    } catch {
        Write-Log "Failed to create scheduled task: $($_.Exception.Message)"
        return $false
    }
}

function Remove-AutoRefreshSchedule {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        Write-Log "Auto-refresh schedule removed."
        return $true
    } catch {
        Write-Log "Failed to remove scheduled task: $($_.Exception.Message)"
        return $false
    }
}

function Get-AutoRefreshSchedule {
    try {
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $t) { return $null }
        $trig = $t.Triggers | Select-Object -First 1
        $intervalStr = $trig.Repetition.Interval
        if (-not $intervalStr) { return $null }
        # Repetition.Interval comes back as an ISO-8601 duration string (e.g. "PT1H"),
        # not a TimeSpan object, so it needs explicit parsing.
        return [System.Xml.XmlConvert]::ToTimeSpan($intervalStr)
    } catch { return $null }
}

# -----------------------------------------------------------------
# Debug-only in-process fallback for sub-minute intervals (see
# $Script:IsDebugBuild above). Ticks for as long as this app instance
# stays open; closing the app or logging off stops it - unlike the real
# scheduled task, it is not persistent.
# -----------------------------------------------------------------
$script:DebugTimer = $null
$script:DebugTimerInterval = $null

function Start-DebugInProcessTimer {
    param([TimeSpan]$Interval, [scriptblock]$OnTick)

    Stop-DebugInProcessTimer
    $script:DebugTimer = New-Object System.Windows.Forms.Timer
    $script:DebugTimer.Interval = [Math]::Max(1, [int]$Interval.TotalMilliseconds)
    $script:DebugTimer.Add_Tick($OnTick)
    $script:DebugTimer.Start()
    $script:DebugTimerInterval = $Interval
    Write-Log "Debug in-process timer started, every $(Format-Interval $Interval) (session-only, stops when the app closes)."
}

function Stop-DebugInProcessTimer {
    if ($script:DebugTimer) {
        $script:DebugTimer.Stop()
        $script:DebugTimer.Dispose()
        $script:DebugTimer = $null
        $script:DebugTimerInterval = $null
    }
}

# -----------------------------------------------------------------
# Real desktop icon (a plain .lnk shortcut, not a floating window)
# that opens the current image's info page when double-clicked.
# -----------------------------------------------------------------
function Get-LearnMoreShortcutPath {
    return "$([Environment]::GetFolderPath('Desktop'))\Spotlight - Learn More.lnk"
}

function Test-LearnMoreShortcutExists {
    return Test-Path (Get-LearnMoreShortcutPath)
}

function New-LearnMoreShortcut {
    try {
        $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $shortcutPath = Get-LearnMoreShortcutPath
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $exePath
        $shortcut.Arguments = "-OpenLearnMore"
        $shortcut.IconLocation = "$exePath,0"
        $shortcut.Description = "Opens info about the current Spotlight desktop image"
        $shortcut.WorkingDirectory = Split-Path $exePath -Parent
        $shortcut.Save()
        [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
        Write-Log "Created desktop shortcut icon at $shortcutPath"
        return $true
    } catch {
        Write-Log "Failed to create desktop shortcut icon: $($_.Exception.Message)"
        return $false
    }
}

function Remove-LearnMoreShortcut {
    try {
        Remove-Item -Path (Get-LearnMoreShortcutPath) -Force -ErrorAction SilentlyContinue
        Write-Log "Removed desktop shortcut icon."
        return $true
    } catch {
        Write-Log "Failed to remove desktop shortcut icon: $($_.Exception.Message)"
        return $false
    }
}

# -----------------------------------------------------------------
# Core rotation logic shared by GUI buttons and silent scheduled runs
# -----------------------------------------------------------------
function Move-SpotlightImage {
    param([ValidateSet("Next","Previous")] [string]$Direction)

    $state = Get-State

    if ($Direction -eq "Next") {
        if ($state.Index -ge ($state.Images.Count - 1)) {
            $new = Get-NewSpotlightImages -Count 4
            $existing = @($state.Images)
            $existingPaths = @($existing | ForEach-Object { $_.Path })
            foreach ($item in $new) {
                if ($existingPaths -notcontains $item.Path) { $existing += $item }
            }
            $state.Images = $existing
        }
        if ($state.Images.Count -eq 0) {
            Write-Log "No images available and none could be downloaded."
            return $null
        }
        $state.Index = [Math]::Min($state.Index + 1, $state.Images.Count - 1)
    } else {
        if ($state.Images.Count -eq 0) {
            Write-Log "No images available to go back to."
            return $null
        }
        $state.Index = [Math]::Max($state.Index - 1, 0)
    }

    $entry = $state.Images[$state.Index]
    if (-not (Test-Path $entry.Path)) {
        Write-Log "Cached image missing on disk, removing from list: $($entry.Path)"
        $state.Images = @($state.Images | Where-Object { $_.Path -ne $entry.Path })
        if ($state.Index -ge $state.Images.Count) { $state.Index = $state.Images.Count - 1 }
        Save-State $state
        return $null
    }

    Set-DesktopWallpaper -Path $entry.Path | Out-Null
    Save-State $state
    return $entry
}

# ============================================================
# Silent mode - invoked by the scheduled task, no UI
# ============================================================
if ($Silent -and $Refresh) {
    try {
        Move-SpotlightImage -Direction "Next" | Out-Null
    } catch {
        Write-Log "Silent refresh failed: $($_.Exception.Message)"
    }
    exit 0
}

# ============================================================
# OpenLearnMore mode - invoked by the desktop shortcut icon.
# Reads whatever image is currently active and opens its info page
# in Chrome, then exits immediately. No window, no background process.
# ============================================================
if ($OpenLearnMore) {
    Add-Type -AssemblyName System.Windows.Forms
    try {
        $state = Get-State
        if ($state.Images.Count -gt 0 -and $state.Index -ge 0) {
            $entry = $state.Images[$state.Index]
            if ($entry.LearnMoreUrl) {
                Open-LearnMoreLink -Url $entry.LearnMoreUrl
            } else {
                Write-Log "Desktop shortcut clicked, but the current image has no info link."
                [System.Windows.Forms.MessageBox]::Show("No info available for the current image.", "Spotlight Manager") | Out-Null
            }
        } else {
            Write-Log "Desktop shortcut clicked, but no image is cached yet."
            [System.Windows.Forms.MessageBox]::Show("No image has been set yet. Open Spotlight Manager and click 'Next' first.", "Spotlight Manager") | Out-Null
        }
    } catch {
        Write-Log "OpenLearnMore failed: $($_.Exception.Message)"
    }
    exit 0
}

# ============================================================
# GUI
# ============================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = if ($Script:IsDebugBuild) { "Spotlight Manager (DEBUG)" } else { "Spotlight Manager" }
$form.Size = New-Object System.Drawing.Size(560, 580)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

$picBox = New-Object System.Windows.Forms.PictureBox
$picBox.Location = New-Object System.Drawing.Point(15, 15)
$picBox.Size = New-Object System.Drawing.Size(530, 200)
$picBox.BorderStyle = "FixedSingle"
$picBox.SizeMode = "Zoom"
$form.Controls.Add($picBox)

$lblInfo = New-Object System.Windows.Forms.Label
$lblInfo.Location = New-Object System.Drawing.Point(15, 220)
$lblInfo.Size = New-Object System.Drawing.Size(530, 20)
$lblInfo.Font = New-Object System.Drawing.Font($lblInfo.Font, [System.Drawing.FontStyle]::Italic)
$lblInfo.AutoEllipsis = $true
$form.Controls.Add($lblInfo)

$btnPrev = New-Object System.Windows.Forms.Button
$btnPrev.Text = "< Previous"
$btnPrev.Location = New-Object System.Drawing.Point(15, 245)
$btnPrev.Size = New-Object System.Drawing.Size(110, 30)
$form.Controls.Add($btnPrev)

$btnLearnMore = New-Object System.Windows.Forms.Button
$btnLearnMore.Text = "Learn More"
$btnLearnMore.Location = New-Object System.Drawing.Point(135, 245)
$btnLearnMore.Size = New-Object System.Drawing.Size(150, 30)
$btnLearnMore.Enabled = $false
$form.Controls.Add($btnLearnMore)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(295, 250)
$lblStatus.Size = New-Object System.Drawing.Size(120, 20)
$lblStatus.TextAlign = "MiddleCenter"
$form.Controls.Add($lblStatus)

$btnNext = New-Object System.Windows.Forms.Button
$btnNext.Text = "Next >"
$btnNext.Location = New-Object System.Drawing.Point(425, 245)
$btnNext.Size = New-Object System.Drawing.Size(120, 30)
$form.Controls.Add($btnNext)

$groupBox = New-Object System.Windows.Forms.GroupBox
$groupBox.Text = "Auto-refresh interval"
$groupBox.Location = New-Object System.Drawing.Point(15, 285)
$groupBox.Size = New-Object System.Drawing.Size(530, 90)
$form.Controls.Add($groupBox)

# Days / Hours / Minutes (/ Seconds, debug build only) fields, each with a
# unit label above it, combined into one TimeSpan when the schedule is set.
$unitFieldWidth = 60
$unitSpacing    = 70
$unitX          = 15

function New-IntervalUnitField {
    param([string]$LabelText, [int]$X, [int]$Max)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $LabelText
    $lbl.Location = New-Object System.Drawing.Point($X, 20)
    $lbl.Size = New-Object System.Drawing.Size($unitFieldWidth, 16)
    $groupBox.Controls.Add($lbl)

    $num = New-Object System.Windows.Forms.NumericUpDown
    $num.Location = New-Object System.Drawing.Point($X, 38)
    $num.Size = New-Object System.Drawing.Size($unitFieldWidth, 25)
    $num.Minimum = 0
    $num.Maximum = $Max
    $num.Value = 0
    $groupBox.Controls.Add($num)
    return $num
}

$numDays    = New-IntervalUnitField -LabelText "Days"    -X ($unitX)                     -Max 3650
$numHours   = New-IntervalUnitField -LabelText "Hours"   -X ($unitX + $unitSpacing)       -Max 23
$numMinutes = New-IntervalUnitField -LabelText "Minutes" -X ($unitX + $unitSpacing * 2)   -Max 59
$numMinutes.Value = 1

$buttonsX = $unitX + $unitSpacing * 3
if ($Script:IsDebugBuild) {
    $numSeconds = New-IntervalUnitField -LabelText "Seconds (debug)" -X ($unitX + $unitSpacing * 3) -Max 59
    $buttonsX = $unitX + $unitSpacing * 4
}

$btnEnable = New-Object System.Windows.Forms.Button
$btnEnable.Text = "Enable"
$btnEnable.Location = New-Object System.Drawing.Point($buttonsX, 38)
$btnEnable.Size = New-Object System.Drawing.Size(90, 28)
$groupBox.Controls.Add($btnEnable)

$btnDisable = New-Object System.Windows.Forms.Button
$btnDisable.Text = "Disable"
$btnDisable.Location = New-Object System.Drawing.Point(($buttonsX + 95), 38)
$btnDisable.Size = New-Object System.Drawing.Size(90, 28)
$groupBox.Controls.Add($btnDisable)

$lblSchedule = New-Object System.Windows.Forms.Label
$lblSchedule.Location = New-Object System.Drawing.Point($unitX, 68)
$lblSchedule.Size = New-Object System.Drawing.Size(495, 18)
$lblSchedule.Font = New-Object System.Drawing.Font($lblSchedule.Font, [System.Drawing.FontStyle]::Italic)
$groupBox.Controls.Add($lblSchedule)

$chkShortcut = New-Object System.Windows.Forms.CheckBox
$chkShortcut.Text = "Show 'Learn More' icon on desktop"
$chkShortcut.Location = New-Object System.Drawing.Point(15, 385)
$chkShortcut.Size = New-Object System.Drawing.Size(530, 24)
$form.Controls.Add($chkShortcut)

$btnDiag = New-Object System.Windows.Forms.Button
$btnDiag.Text = "Run Diagnostics && Fix"
$btnDiag.Location = New-Object System.Drawing.Point(15, 415)
$btnDiag.Size = New-Object System.Drawing.Size(530, 30)
$form.Controls.Add($btnDiag)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(15, 455)
$txtLog.Size = New-Object System.Drawing.Size(530, 80)
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 8)
$form.Controls.Add($txtLog)

function Append-Log($msg) {
    $txtLog.AppendText("$msg`r`n")
}

function Refresh-ScheduleLabel {
    if ($script:DebugTimer) {
        $lblSchedule.Text = "DEBUG in-process timer active: every $(Format-Interval $script:DebugTimerInterval) (session-only)"
        return
    }
    $interval = Get-AutoRefreshSchedule
    if ($interval) {
        $lblSchedule.Text = "Active: every $(Format-Interval $interval)"
    } else {
        $lblSchedule.Text = "Not scheduled"
    }
}

$script:CurrentLearnMoreUrl = $null

function Update-Image($entry) {
    if ($entry -and $entry.Path -and (Test-Path $entry.Path)) {
        if ($picBox.Image) { $picBox.Image.Dispose() }
        $picBox.Image = [System.Drawing.Image]::FromFile($entry.Path)
        $state = Get-State
        $lblStatus.Text = "Image $($state.Index + 1) of $($state.Images.Count)"

        if ($entry.Title -or $entry.Copyright) {
            $parts = @($entry.Title, $entry.Copyright) | Where-Object { $_ }
            $lblInfo.Text = [string]::Join("  -  ", $parts)
        } else {
            $lblInfo.Text = ""
        }

        $script:CurrentLearnMoreUrl = $entry.LearnMoreUrl
        $btnLearnMore.Enabled = [bool]$entry.LearnMoreUrl
    } else {
        $lblStatus.Text = "No image available"
        $lblInfo.Text = ""
        $script:CurrentLearnMoreUrl = $null
        $btnLearnMore.Enabled = $false
    }
}

$btnNext.Add_Click({
    $btnNext.Enabled = $false; $btnPrev.Enabled = $false
    $form.Cursor = "WaitCursor"
    try {
        $entry = Move-SpotlightImage -Direction "Next"
        Update-Image $entry
        if (-not $entry) { Append-Log "Could not fetch/display a new image. Check log.txt for details." }
    } finally {
        $form.Cursor = "Default"
        $btnNext.Enabled = $true; $btnPrev.Enabled = $true
    }
})

$btnLearnMore.Add_Click({
    if ($script:CurrentLearnMoreUrl) {
        Open-LearnMoreLink -Url $script:CurrentLearnMoreUrl
    }
})

$btnPrev.Add_Click({
    $btnPrev.Enabled = $false; $btnNext.Enabled = $false
    $form.Cursor = "WaitCursor"
    try {
        $entry = Move-SpotlightImage -Direction "Previous"
        Update-Image $entry
    } finally {
        $form.Cursor = "Default"
        $btnPrev.Enabled = $true; $btnNext.Enabled = $true
    }
})

$btnDiag.Add_Click({
    $btnDiag.Enabled = $false
    $txtLog.Clear()
    Append-Log "Running diagnostics..."
    try {
        Invoke-Diagnostics -LogCallback { param($m) Append-Log $m }
    } catch {
        Append-Log "Unexpected error: $($_.Exception.Message)"
    } finally {
        $btnDiag.Enabled = $true
        Append-Log "Done."
    }
})

$btnEnable.Add_Click({
    $seconds = 0
    if ($Script:IsDebugBuild) { $seconds = [int]$numSeconds.Value }
    $interval = New-TimeSpan -Days ([int]$numDays.Value) -Hours ([int]$numHours.Value) -Minutes ([int]$numMinutes.Value) -Seconds $seconds

    if ($interval.TotalSeconds -le 0) {
        Append-Log "Enter an interval greater than zero."
        return
    }

    if ($Script:IsDebugBuild -and $interval.TotalSeconds -lt 60) {
        # Task Scheduler cannot repeat faster than once a minute, so this
        # debug-only path drives the rotation directly from the running
        # process instead - see Start-DebugInProcessTimer above.
        Remove-AutoRefreshSchedule | Out-Null
        Start-DebugInProcessTimer -Interval $interval -OnTick {
            $entry = Move-SpotlightImage -Direction "Next"
            Update-Image $entry
        }
        Append-Log "DEBUG: using in-process timer every $(Format-Interval $interval) (under Task Scheduler's 60s floor - session-only)."
    } else {
        Stop-DebugInProcessTimer
        if (Set-AutoRefreshSchedule -Interval $interval) {
            Append-Log "Auto-refresh enabled: every $(Format-Interval $interval)."
        } else {
            Append-Log "Failed to enable auto-refresh. Check log.txt for details."
        }
    }
    Refresh-ScheduleLabel
})

$btnDisable.Add_Click({
    Stop-DebugInProcessTimer
    Remove-AutoRefreshSchedule | Out-Null
    Append-Log "Auto-refresh disabled."
    Refresh-ScheduleLabel
})

$script:InitializingShortcutCheckbox = $false

$chkShortcut.Add_CheckedChanged({
    if ($script:InitializingShortcutCheckbox) { return }
    if ($chkShortcut.Checked) {
        if (New-LearnMoreShortcut) {
            Append-Log "Added 'Spotlight - Learn More' icon to the desktop."
        } else {
            Append-Log "Failed to create the desktop icon. Check log.txt."
        }
    } else {
        Remove-LearnMoreShortcut | Out-Null
        Append-Log "Removed the desktop icon."
    }
})

$form.Add_Shown({
    Refresh-ScheduleLabel
    $state = Get-State
    if ($state.Images.Count -gt 0 -and $state.Index -ge 0) {
        Update-Image $state.Images[$state.Index]
    } else {
        Append-Log "No cached images yet. Click 'Next' to fetch the first one."
    }

    $script:InitializingShortcutCheckbox = $true
    $chkShortcut.Checked = Test-LearnMoreShortcutExists
    $script:InitializingShortcutCheckbox = $false
})

$form.Add_FormClosing({ Stop-DebugInProcessTimer })

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)

