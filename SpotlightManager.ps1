param(
    [switch]$Silent,
    [switch]$Refresh,
    [switch]$ElevatedFix,
    [switch]$OpenLearnMore,
    [switch]$NextWallpaper
)

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
$ShortcutHelperPath = "$AppDir\SpotlightManagerShortcut.exe"
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

function Limit-ImageHistory {
    param($State)

    $currentPath = $null
    if ($State.Index -ge 0 -and $State.Index -lt $State.Images.Count) {
        $currentPath = $State.Images[$State.Index].Path
    }

    $images = @($State.Images | Where-Object { $_.Path -and (Test-Path -LiteralPath $_.Path) })
    if ($images.Count -eq 0) {
        $State.Images = @()
        $State.Index = -1
        return
    }

    $currentIndex = 0
    if ($currentPath) {
        for ($i = 0; $i -lt $images.Count; $i++) {
            if ([string]::Equals($images[$i].Path, $currentPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                $currentIndex = $i
                break
            }
        }
    }

    # Keep only the selected image and one adjacent image for a single-step undo.
    $start = [Math]::Max(0, $currentIndex - 1)
    $end = [Math]::Min($images.Count - 1, $start + 1)
    $start = [Math]::Max(0, $end - 1)
    $kept = @($images[$start..$end])
    $keepPaths = @($kept | ForEach-Object { $_.Path })

    $removed = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $CacheDir -File -Filter '*.jpg' -ErrorAction SilentlyContinue)) {
        if ($keepPaths -notcontains $file.FullName) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $file.FullName)) { $removed++ }
        }
    }

    $State.Images = $kept
    $State.Index = [Math]::Max(0, $currentIndex - $start)
    if ($removed -gt 0) { Write-Log "Removed $removed old cached image(s)." }
}

# -----------------------------------------------------------------
# Fetch fresh images from Microsoft's Spotlight API into our own
# user-writable cache (never touches protected system folders).
# -----------------------------------------------------------------
function Get-NewSpotlightImages {
    param([int]$Count = 1)

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
    if ($parts.Count -eq 0) { return "0m" }
    return ($parts -join " ")
}

# Task Scheduler's repetition trigger rejects any interval under 60 seconds
# (confirmed: registering with e.g. PT30S throws "value ... out of range"),
# so anything faster than that cannot go through Register-ScheduledTask at all.
#
# The task launches this no-console exe directly. All application and refresh
# logic therefore stays in the single exe, and no PowerShell console window
# can flash when the wallpaper changes.
function Set-AutoRefreshSchedule {
    param([TimeSpan]$Interval)

    try {
        $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $hostName = [System.IO.Path]::GetFileName($exePath)
        if ($hostName -in @("powershell.exe", "powershell_ise.exe", "pwsh.exe")) {
            throw "Auto-refresh can only be enabled from the compiled SpotlightManager.exe."
        }
        $action = New-ScheduledTaskAction -Execute $exePath -Argument "-Silent -Refresh"
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval $Interval -RepetitionDuration (New-TimeSpan -Days 3650)
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description "Rotates the desktop Spotlight image silently using SpotlightManager.exe." -Force -ErrorAction Stop | Out-Null

        # A task created while the app is elevated otherwise gives the normal
        # user read-only access, making later interval changes fail. Explicitly
        # keep this per-user task editable at either integrity level.
        try {
            $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $taskService = New-Object -ComObject "Schedule.Service"
            $taskService.Connect()
            $registeredTask = $taskService.GetFolder("\").GetTask($TaskName)
            $taskSddl = "D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;$userSid)"
            $registeredTask.SetSecurityDescriptor($taskSddl, 0)
        } catch {
            Write-Log "Scheduled task was updated, but its edit permissions could not be normalized: $($_.Exception.Message)"
        }

        Write-Log "Auto-refresh scheduled every $(Format-Interval $Interval) using $exePath."
        return $true
    } catch {
        Write-Log "Failed to create or update scheduled task: $($_.Exception.Message)"
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

function Sync-AutoRefreshScheduleAction {
    # Upgrade legacy powershell.exe/EncodedCommand tasks, and repair the task
    # automatically if this portable exe has been moved since it was enabled.
    try {
        $interval = Get-AutoRefreshSchedule
        if (-not $interval) { return $false }

        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $action = $task.Actions | Select-Object -First 1
        $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $correctExe = [string]::Equals($action.Execute, $exePath, [System.StringComparison]::OrdinalIgnoreCase)
        $correctArguments = ([string]$action.Arguments).Trim() -eq "-Silent -Refresh"

        if (-not $correctExe -or -not $correctArguments) {
            if (-not (Set-AutoRefreshSchedule -Interval $interval)) {
                throw "Could not replace the scheduled task action."
            }
            Write-Log "Updated auto-refresh task to use the current no-console exe."
            return $true
        }
    } catch {
        Write-Log "Failed to update auto-refresh task action: $($_.Exception.Message)"
    }
    return $false
}

# -----------------------------------------------------------------
# Real desktop icon (a plain .lnk shortcut, not a floating window)
# that opens the current image's info page when double-clicked.
# -----------------------------------------------------------------
function Get-LearnMoreShortcutPath {
    return "$([Environment]::GetFolderPath('Desktop'))\Spotlight - Learn More.lnk"
}

function Get-NextWallpaperShortcutPath {
    return "$([Environment]::GetFolderPath('Desktop'))\Spotlight - Next Wallpaper.lnk"
}

function Test-LearnMoreShortcutExists {
    return Test-Path (Get-LearnMoreShortcutPath)
}

function Test-NextWallpaperShortcutExists {
    return Test-Path (Get-NextWallpaperShortcutPath)
}

function Install-ShortcutHelper {
    $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $hostName = [System.IO.Path]::GetFileName($exePath)
    if ($hostName -in @("powershell.exe", "powershell_ise.exe", "pwsh.exe")) {
        throw "Desktop shortcuts can only be enabled from the compiled SpotlightManager.exe."
    }

    # Keep both shortcuts independent from the portable executable. Users can
    # delete or move the original after setup without breaking either shortcut.
    if (-not [string]::Equals($exePath, $ShortcutHelperPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $exePath -Destination $ShortcutHelperPath -Force
    }
}

function Remove-ShortcutHelperIfUnused {
    if (-not (Test-LearnMoreShortcutExists) -and -not (Test-NextWallpaperShortcutExists)) {
        Remove-Item -LiteralPath $ShortcutHelperPath -Force -ErrorAction SilentlyContinue
    }
}

function New-LearnMoreShortcut {
    try {
        Install-ShortcutHelper

        $shortcutPath = Get-LearnMoreShortcutPath
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $ShortcutHelperPath
        $shortcut.Arguments = "-OpenLearnMore"
        $shortcut.IconLocation = "$ShortcutHelperPath,0"
        $shortcut.Description = "Opens info about the current Spotlight desktop image"
        $shortcut.WorkingDirectory = $AppDir
        $shortcut.Save()
        [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
        Write-Log "Created desktop shortcut icon at $shortcutPath"
        return $true
    } catch {
        Write-Log "Failed to create desktop shortcut icon: $($_.Exception.Message)"
        return $false
    }
}

function New-NextWallpaperShortcut {
    try {
        Install-ShortcutHelper

        $shortcutPath = Get-NextWallpaperShortcutPath
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $ShortcutHelperPath
        $shortcut.Arguments = "-NextWallpaper"
        $shortcut.IconLocation = "$ShortcutHelperPath,0"
        $shortcut.Description = "Switches to the next Spotlight desktop image"
        $shortcut.WorkingDirectory = $AppDir
        $shortcut.Save()
        [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
        Write-Log "Created next-wallpaper desktop shortcut at $shortcutPath"
        return $true
    } catch {
        Write-Log "Failed to create next-wallpaper desktop shortcut: $($_.Exception.Message)"
        return $false
    }
}

function Remove-LearnMoreShortcut {
    try {
        Remove-Item -Path (Get-LearnMoreShortcutPath) -Force -ErrorAction SilentlyContinue
        Remove-ShortcutHelperIfUnused
        Write-Log "Removed Learn More desktop shortcut."
        return $true
    } catch {
        Write-Log "Failed to remove Learn More desktop shortcut: $($_.Exception.Message)"
        return $false
    }
}

function Remove-NextWallpaperShortcut {
    try {
        Remove-Item -Path (Get-NextWallpaperShortcutPath) -Force -ErrorAction SilentlyContinue
        Remove-ShortcutHelperIfUnused
        Write-Log "Removed next-wallpaper desktop shortcut."
        return $true
    } catch {
        Write-Log "Failed to remove next-wallpaper desktop shortcut: $($_.Exception.Message)"
        return $false
    }
}

# -----------------------------------------------------------------
# Core rotation logic shared by GUI buttons and silent scheduled runs
# -----------------------------------------------------------------
function Move-SpotlightImage {
    param([ValidateSet("Next", "Previous")] [string]$Direction = "Next")

    $state = Get-State

    if ($Direction -eq "Previous") {
        if ($state.Index -le 0 -or $state.Images.Count -lt 2) {
            Write-Log "No previous image is available."
            return $null
        }
        $state.Index--
    } elseif ($state.Index -lt ($state.Images.Count - 1)) {
        $state.Index++
    } else {
        $newImages = @(Get-NewSpotlightImages -Count 1)
        if ($newImages.Count -eq 0) {
            Write-Log "No new image could be downloaded."
            return $null
        }
        $newEntry = $newImages[0]
        $existingPaths = @($state.Images | ForEach-Object { $_.Path })
        if ($existingPaths -notcontains $newEntry.Path) {
            $state.Images = @($state.Images) + $newEntry
            $state.Index = $state.Images.Count - 1
        }
    }

    if ($state.Images.Count -eq 0 -or $state.Index -lt 0) { return $null }
    $entry = $state.Images[$state.Index]
    Set-DesktopWallpaper -Path $entry.Path | Out-Null
    Limit-ImageHistory -State $state
    Save-State $state
    return $entry
}

# ============================================================
# Silent mode - invoked by the scheduled task, no UI
# ============================================================
if ($Silent -and $Refresh) {
    try {
        Move-SpotlightImage | Out-Null
    } catch {
        Write-Log "Silent refresh failed: $($_.Exception.Message)"
    }
    exit 0
}

# ============================================================
# NextWallpaper mode - invoked by the desktop shortcut icon.
# Uses the helper copy in LocalAppData, so the original portable EXE is not
# required after the shortcut has been enabled.
# ============================================================
if ($NextWallpaper) {
    try {
        Move-SpotlightImage | Out-Null
    } catch {
        Write-Log "Next-wallpaper shortcut failed: $($_.Exception.Message)"
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
# GUI - dark theme
# ============================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Use real DPI scaling so text and controls grow together on scaled displays.
if (-not ([System.Management.Automation.PSTypeName]'Native.DpiAwareness').Type) {
    Add-Type -Namespace Native -Name DpiAwareness -MemberDefinition @"
[DllImport("user32.dll")]
public static extern bool SetProcessDPIAware();
"@
}
[Native.DpiAwareness]::SetProcessDPIAware() | Out-Null

$clrBg      = [System.Drawing.Color]::FromArgb(255, 16, 18, 24)
$clrPanel   = [System.Drawing.Color]::FromArgb(255, 27, 31, 39)
$clrPanel2  = [System.Drawing.Color]::FromArgb(255, 39, 44, 54)
$clrAccent  = [System.Drawing.Color]::FromArgb(255, 124, 92, 252)
$clrText    = [System.Drawing.Color]::FromArgb(255, 241, 243, 247)
$clrMuted   = [System.Drawing.Color]::FromArgb(255, 159, 168, 184)
$fontMain   = New-Object System.Drawing.Font("Segoe UI", 10)
$fontBold   = New-Object System.Drawing.Font("Segoe UI Semibold", 10.5)
$fontTitle  = New-Object System.Drawing.Font("Segoe UI Semibold", 18)

function New-FlatButton {
    param([string]$Text, [System.Drawing.Color]$Back, [System.Drawing.Color]$Fore = $clrText)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.FlatStyle = "Flat"
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $Back
    $b.ForeColor = $Fore
    $b.Font = $fontBold
    $b.Cursor = "Hand"
    $b.UseVisualStyleBackColor = $false
    return $b
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.Text = "Spotlight Manager"
$form.ClientSize = New-Object System.Drawing.Size(1000, 880)
$form.MinimumSize = New-Object System.Drawing.Size(900, 760)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "Sizable"
$form.MaximizeBox = $true
$form.MinimizeBox = $true
$form.BackColor = $clrBg
$form.ForeColor = $clrText
$form.Font = $fontMain

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "Spotlight Manager"
$lblTitle.Font = $fontTitle
$lblTitle.ForeColor = $clrText
$lblTitle.Location = New-Object System.Drawing.Point(16, 10)
$lblTitle.Size = New-Object System.Drawing.Size(968, 58)
$lblTitle.Anchor = "Top,Left,Right"
$form.Controls.Add($lblTitle)

$previewPanel = New-Object System.Windows.Forms.Panel
$previewPanel.Location = New-Object System.Drawing.Point(16, 76)
$previewPanel.Size = New-Object System.Drawing.Size(680, 491)
$previewPanel.Anchor = "Top,Left,Right"
$previewPanel.BackColor = $clrBg
$form.Controls.Add($previewPanel)

$picPanel = New-Object System.Windows.Forms.PictureBox
$picPanel.Location = New-Object System.Drawing.Point(0, 0)
$picPanel.Size = New-Object System.Drawing.Size(680, 383)
$picPanel.Anchor = "Top,Left,Right"
$picPanel.BackColor = [System.Drawing.Color]::Black
$picPanel.BorderStyle = "FixedSingle"
$picPanel.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
$previewPanel.Controls.Add($picPanel)

$script:currentImage = $null

$lblInfo = New-Object System.Windows.Forms.Label
$lblInfo.Location = New-Object System.Drawing.Point(0, 391)
$lblInfo.Size = New-Object System.Drawing.Size(680, 44)
$lblInfo.Anchor = "Top,Left,Right"
$lblInfo.BackColor = $clrPanel
$lblInfo.ForeColor = $clrText
$lblInfo.TextAlign = "MiddleLeft"
$lblInfo.Padding = New-Object System.Windows.Forms.Padding(12, 4, 12, 4)
$lblInfo.AutoEllipsis = $true
$previewPanel.Controls.Add($lblInfo)

# Clicking the image itself does the same thing as the Learn More button -
# $lblInfo is a child control sitting on top of the image, so it needs its
# own handler too (a click on a child doesn't bubble up to the parent's).
$openLearnMoreForCurrentImage = {
    if ($script:CurrentLearnMoreUrl) {
        Open-LearnMoreLink -Url $script:CurrentLearnMoreUrl
    }
}
$picPanel.Cursor = "Hand"
$picPanel.Add_Click($openLearnMoreForCurrentImage)
$lblInfo.Cursor = "Hand"
$lblInfo.Add_Click($openLearnMoreForCurrentImage)

$previewActions = New-Object System.Windows.Forms.Panel
$previewActions.Location = New-Object System.Drawing.Point(0, 443)
$previewActions.Size = New-Object System.Drawing.Size(680, 48)
$previewActions.Anchor = "Top,Left,Right"
$previewActions.BackColor = $clrBg
$previewPanel.Controls.Add($previewActions)

$btnPrev = New-FlatButton "BACK" $clrPanel2
$btnPrev.Location = New-Object System.Drawing.Point(0, 0)
$btnPrev.Size = New-Object System.Drawing.Size(100, 44)
$btnPrev.Anchor = "Top,Left"
$btnPrev.Enabled = $false
$previewActions.Controls.Add($btnPrev)

$btnLearnMore = New-FlatButton "INFO" $clrPanel2
$btnLearnMore.Location = New-Object System.Drawing.Point(108, 0)
$btnLearnMore.Size = New-Object System.Drawing.Size(100, 44)
$btnLearnMore.Anchor = "Top,Left"
$btnLearnMore.Enabled = $false
$previewActions.Controls.Add($btnLearnMore)

$btnNext = New-FlatButton "NEXT" $clrAccent
$btnNext.Location = New-Object System.Drawing.Point(216, 0)
$btnNext.Size = New-Object System.Drawing.Size(112, 44)
$btnNext.Anchor = "Top,Left"
$previewActions.Controls.Add($btnNext)

$groupBox = New-Object System.Windows.Forms.Panel
$groupBox.Location = New-Object System.Drawing.Point(712, 76)
$groupBox.Size = New-Object System.Drawing.Size(272, 491)
$groupBox.Anchor = "Top,Right"
$groupBox.BackColor = $clrPanel
$form.Controls.Add($groupBox)

$lblGroupTitle = New-Object System.Windows.Forms.Label
$lblGroupTitle.Text = "AUTO-REFRESH"
$lblGroupTitle.ForeColor = $clrMuted
$lblGroupTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$lblGroupTitle.Location = New-Object System.Drawing.Point(16, 12)
$lblGroupTitle.Size = New-Object System.Drawing.Size(240, 34)
$groupBox.Controls.Add($lblGroupTitle)

function New-IntervalUnitField {
    param([string]$LabelText, [int]$Y, [int]$Max)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $LabelText
    $lbl.ForeColor = $clrMuted
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
    $lbl.Location = New-Object System.Drawing.Point(16, ($Y + 6))
    $lbl.Size = New-Object System.Drawing.Size(76, 40)
    $groupBox.Controls.Add($lbl)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Text = "0"
    $textBox.Location = New-Object System.Drawing.Point(132, $Y)
    $textBox.Size = New-Object System.Drawing.Size(68, 46)
    $textBox.BackColor = $clrPanel2
    $textBox.ForeColor = $clrText
    $textBox.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 13)
    $textBox.TextAlign = "Center"
    $textBox.BorderStyle = "FixedSingle"
    $textBox.Tag = $Max
    $textBox.Add_KeyPress({
        param($sender, $e)
        if (-not [char]::IsControl($e.KeyChar) -and -not [char]::IsDigit($e.KeyChar)) { $e.Handled = $true }
    })
    $textBox.Add_Leave({
        $value = 0
        if (-not [int]::TryParse($textBox.Text, [ref]$value)) { $value = 0 }
        $textBox.Text = [Math]::Max(0, [Math]::Min($Max, $value)).ToString()
    }.GetNewClosure())
    $groupBox.Controls.Add($textBox)

    $minus = New-FlatButton "-" $clrPanel2
    $minus.Location = New-Object System.Drawing.Point(92, $Y)
    $minus.Size = New-Object System.Drawing.Size(40, 46)
    $minus.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 12)
    $minus.Add_Click({
        $value = 0
        [int]::TryParse($textBox.Text, [ref]$value) | Out-Null
        if ($value -gt 0) { $textBox.Text = ($value - 1).ToString() }
    }.GetNewClosure())
    $groupBox.Controls.Add($minus)

    $plus = New-FlatButton "+" $clrPanel2
    $plus.Location = New-Object System.Drawing.Point(200, $Y)
    $plus.Size = New-Object System.Drawing.Size(40, 46)
    $plus.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 12)
    $plus.Add_Click({
        $value = 0
        [int]::TryParse($textBox.Text, [ref]$value) | Out-Null
        if ($value -lt $Max) { $textBox.Text = ($value + 1).ToString() }
    }.GetNewClosure())
    $groupBox.Controls.Add($plus)

    return $textBox
}

$numDays    = New-IntervalUnitField -LabelText "Days"    -Y 54  -Max 3650
$numHours   = New-IntervalUnitField -LabelText "Hours"   -Y 106 -Max 23
$numMinutes = New-IntervalUnitField -LabelText "Minutes" -Y 158 -Max 59
$numMinutes.Text = "1"

$btnEnable = New-FlatButton "ENABLE" $clrAccent
$btnEnable.Location = New-Object System.Drawing.Point(16, 218)
$btnEnable.Size = New-Object System.Drawing.Size(112, 46)
$groupBox.Controls.Add($btnEnable)

$btnDisable = New-FlatButton "DISABLE" $clrPanel2
$btnDisable.Location = New-Object System.Drawing.Point(136, 218)
$btnDisable.Size = New-Object System.Drawing.Size(120, 46)
$groupBox.Controls.Add($btnDisable)

$lblSchedule = New-Object System.Windows.Forms.Label
$lblSchedule.Location = New-Object System.Drawing.Point(16, 274)
$lblSchedule.Size = New-Object System.Drawing.Size(240, 48)
$lblSchedule.ForeColor = $clrMuted
$lblSchedule.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Italic)
$groupBox.Controls.Add($lblSchedule)

$lblTools = New-Object System.Windows.Forms.Label
$lblTools.Text = "SHORTCUTS"
$lblTools.UseMnemonic = $false
$lblTools.ForeColor = $clrMuted
$lblTools.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$lblTools.Location = New-Object System.Drawing.Point(16, 326)
$lblTools.Size = New-Object System.Drawing.Size(240, 30)
$groupBox.Controls.Add($lblTools)

$chkShortcut = New-Object System.Windows.Forms.CheckBox
$chkShortcut.Text = "Learn More"
$chkShortcut.ForeColor = $clrText
$chkShortcut.Location = New-Object System.Drawing.Point(16, 358)
$chkShortcut.Size = New-Object System.Drawing.Size(240, 34)
$groupBox.Controls.Add($chkShortcut)

$chkNextShortcut = New-Object System.Windows.Forms.CheckBox
$chkNextShortcut.Text = "Next Wallpaper"
$chkNextShortcut.ForeColor = $clrText
$chkNextShortcut.Location = New-Object System.Drawing.Point(16, 392)
$chkNextShortcut.Size = New-Object System.Drawing.Size(240, 34)
$groupBox.Controls.Add($chkNextShortcut)

$btnDiag = New-FlatButton "DIAGNOSTICS && FIX" $clrPanel2
$btnDiag.Location = New-Object System.Drawing.Point(16, 436)
$btnDiag.Size = New-Object System.Drawing.Size(240, 42)
$groupBox.Controls.Add($btnDiag)

$lblActivity = New-Object System.Windows.Forms.Label
$lblActivity.Text = "ACTIVITY"
$lblActivity.ForeColor = $clrMuted
$lblActivity.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$lblActivity.Location = New-Object System.Drawing.Point(16, 588)
$lblActivity.Size = New-Object System.Drawing.Size(968, 32)
$lblActivity.Anchor = "Top,Left"
$form.Controls.Add($lblActivity)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(16, 620)
$txtLog.Size = New-Object System.Drawing.Size(968, 236)
$txtLog.Anchor = "Top,Bottom,Left,Right"
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9.5)
$txtLog.BackColor = $clrPanel
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(255, 140, 220, 150)
$txtLog.BorderStyle = "FixedSingle"
$form.Controls.Add($txtLog)

function Append-Log($msg) {
    $txtLog.AppendText("$msg`r`n")
}

function Refresh-ScheduleLabel {
    $interval = Get-AutoRefreshSchedule
    if ($interval) {
        $lblSchedule.Text = "Active: every $(Format-Interval $interval)"
        $numDays.Text = $interval.Days.ToString()
        $numHours.Text = $interval.Hours.ToString()
        $numMinutes.Text = $interval.Minutes.ToString()
    } else {
        $lblSchedule.Text = "Not scheduled"
    }
}

$script:CurrentLearnMoreUrl = $null

function Update-Image($entry) {
    if ($entry -and $entry.Path -and (Test-Path $entry.Path)) {
        if ($script:currentImage) { $script:currentImage.Dispose() }
        $script:currentImage = [System.Drawing.Image]::FromFile($entry.Path)
        $picPanel.Image = $script:currentImage
        if ($entry.Title -or $entry.Copyright) {
            $parts = @($entry.Title, $entry.Copyright) | Where-Object { $_ }
            $lblInfo.Text = [string]::Join("  -  ", $parts)
        } else {
            $lblInfo.Text = ""
        }

        $script:CurrentLearnMoreUrl = $entry.LearnMoreUrl
        $btnLearnMore.Enabled = [bool]$entry.LearnMoreUrl
    } else {
        $lblInfo.Text = ""
        $script:CurrentLearnMoreUrl = $null
        $btnLearnMore.Enabled = $false
    }
}

function Update-NavigationState {
    $state = Get-State
    $btnPrev.Enabled = ($state.Images.Count -gt 1 -and $state.Index -gt 0)
    $btnNext.Enabled = $true
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
        Update-NavigationState
    }
})

$btnLearnMore.Add_Click($openLearnMoreForCurrentImage)

$btnPrev.Add_Click({
    $btnPrev.Enabled = $false; $btnNext.Enabled = $false
    $form.Cursor = "WaitCursor"
    try {
        $entry = Move-SpotlightImage -Direction "Previous"
        Update-Image $entry
        if (-not $entry) { Append-Log "No previous image is available." }
    } finally {
        $form.Cursor = "Default"
        Update-NavigationState
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
    $days = 0
    $hours = 0
    $minutes = 0
    [int]::TryParse($numDays.Text, [ref]$days) | Out-Null
    [int]::TryParse($numHours.Text, [ref]$hours) | Out-Null
    [int]::TryParse($numMinutes.Text, [ref]$minutes) | Out-Null
    $days = [Math]::Max(0, [Math]::Min(3650, $days))
    $hours = [Math]::Max(0, [Math]::Min(23, $hours))
    $minutes = [Math]::Max(0, [Math]::Min(59, $minutes))
    $numDays.Text = $days.ToString()
    $numHours.Text = $hours.ToString()
    $numMinutes.Text = $minutes.ToString()
    $interval = New-TimeSpan -Days $days -Hours $hours -Minutes $minutes

    if ($interval.TotalSeconds -le 0) {
        Append-Log "Enter an interval greater than zero."
        return
    }
    if ($interval.TotalSeconds -lt 60) {
        Append-Log "Task Scheduler can't repeat faster than once a minute - enter at least 1 minute."
        return
    }

    if (Set-AutoRefreshSchedule -Interval $interval) {
        Append-Log "Auto-refresh enabled: every $(Format-Interval $interval)."
    } else {
        Append-Log "Failed to enable auto-refresh. Check log.txt for details."
    }
    Refresh-ScheduleLabel
})

$btnDisable.Add_Click({
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

$chkNextShortcut.Add_CheckedChanged({
    if ($script:InitializingShortcutCheckbox) { return }
    if ($chkNextShortcut.Checked) {
        if (New-NextWallpaperShortcut) {
            Append-Log "Added 'Spotlight - Next Wallpaper' icon to the desktop."
        } else {
            Append-Log "Failed to create the next-wallpaper desktop icon. Check log.txt."
        }
    } else {
        Remove-NextWallpaperShortcut | Out-Null
        Append-Log "Removed the next-wallpaper desktop icon."
    }
})

$form.Add_Shown({
    if (Sync-AutoRefreshScheduleAction) {
        Append-Log "Updated the existing auto-refresh schedule to run without a console flash."
    }
    Refresh-ScheduleLabel
    $state = Get-State
    Limit-ImageHistory -State $state
    Save-State $state
    if ($state.Images.Count -gt 0 -and $state.Index -ge 0) {
        Update-Image $state.Images[$state.Index]
    } else {
        Append-Log "No cached images yet. Click 'Next' to fetch the first one."
    }

    $shortcutExists = Test-LearnMoreShortcutExists
    if ($shortcutExists -and (New-LearnMoreShortcut)) {
        Append-Log "Updated the existing Learn More desktop icon."
    }
    $nextShortcutExists = Test-NextWallpaperShortcutExists
    if ($nextShortcutExists -and (New-NextWallpaperShortcut)) {
        Append-Log "Updated the existing Next Wallpaper desktop icon."
    }

    $script:InitializingShortcutCheckbox = $true
    $chkShortcut.Checked = $shortcutExists
    $chkNextShortcut.Checked = $nextShortcutExists
    $script:InitializingShortcutCheckbox = $false
    Update-NavigationState
})

[System.Windows.Forms.Application]::Run($form)
