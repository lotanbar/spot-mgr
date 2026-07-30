param(
    [switch]$Silent,
    [switch]$Refresh,
    [switch]$ElevatedFix,
    [switch]$OpenLearnMore,
    [string]$ExportSource
)

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
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

        $action = New-ScheduledTaskAction -Execute $exePath -Argument "-Silent -Refresh"
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval $Interval -RepetitionDuration (New-TimeSpan -Days 3650)
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description "Rotates the desktop Spotlight image silently using SpotlightManager.exe." | Out-Null
        Write-Log "Auto-refresh scheduled every $(Format-Interval $Interval) using $exePath."
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
# GUI - dark theme
# ============================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$clrBg      = [System.Drawing.Color]::FromArgb(255, 18, 18, 22)
$clrPanel   = [System.Drawing.Color]::FromArgb(255, 30, 30, 36)
$clrPanel2  = [System.Drawing.Color]::FromArgb(255, 40, 40, 48)
$clrAccent  = [System.Drawing.Color]::FromArgb(255, 130, 90, 255)
$clrText    = [System.Drawing.Color]::FromArgb(255, 235, 235, 240)
$clrMuted   = [System.Drawing.Color]::FromArgb(255, 150, 150, 160)
$fontMain   = New-Object System.Drawing.Font("Segoe UI", 9.5)
$fontBold   = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$fontTitle  = New-Object System.Drawing.Font("Segoe UI Semibold", 13)

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
    return $b
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Spotlight Manager"
$form.Size = New-Object System.Drawing.Size(620, 700)
$form.MinimumSize = New-Object System.Drawing.Size(620, 700)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "Sizable"
$form.MaximizeBox = $true
$form.MinimizeBox = $true
$form.BackColor = $clrBg
$form.ForeColor = $clrText
$form.Font = $fontMain

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "SPOTLIGHT MANAGER"
$lblTitle.Font = $fontTitle
$lblTitle.ForeColor = $clrAccent
$lblTitle.Location = New-Object System.Drawing.Point(20, 15)
$lblTitle.Size = New-Object System.Drawing.Size(400, 30)
$lblTitle.Anchor = "Top,Left"
$form.Controls.Add($lblTitle)

$picPanel = New-Object System.Windows.Forms.Panel
$picPanel.Location = New-Object System.Drawing.Point(20, 55)
$picPanel.Size = New-Object System.Drawing.Size(566, 270)
$picPanel.Anchor = "Top,Left,Right,Bottom"
$picPanel.BackColor = [System.Drawing.Color]::Black
$form.Controls.Add($picPanel)

# Custom "cover" draw (crop-to-fill, no letterboxing) so the preview mirrors
# how Windows itself renders a Fill-style wallpaper, instead of PictureBox's
# Zoom mode which pads with black bars.
$script:currentImage = $null
$picPanel.Add_Paint({
    param($sender, $e)
    if ($script:currentImage) {
        $img = $script:currentImage
        $panelW = $picPanel.ClientSize.Width
        $panelH = $picPanel.ClientSize.Height
        if ($panelW -gt 0 -and $panelH -gt 0) {
            $scale = [Math]::Max($panelW / $img.Width, $panelH / $img.Height)
            $destW = $img.Width * $scale
            $destH = $img.Height * $scale
            $destX = ($panelW - $destW) / 2
            $destY = ($panelH - $destH) / 2
            $e.Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $e.Graphics.DrawImage($img, $destX, $destY, $destW, $destH)
        }
    }
    $borderPen = New-Object System.Drawing.Pen($clrAccent, 1)
    $e.Graphics.DrawRectangle($borderPen, 0, 0, $picPanel.ClientSize.Width - 1, $picPanel.ClientSize.Height - 1)
    $borderPen.Dispose()
})
$picPanel.Add_Resize({ $picPanel.Invalidate() })

# Caption bar overlaid on the bottom edge of the preview, instead of a
# separate row - keeps the image itself the focal point.
$lblInfo = New-Object System.Windows.Forms.Label
$lblInfo.Location = New-Object System.Drawing.Point(0, 240)
$lblInfo.Size = New-Object System.Drawing.Size(566, 30)
$lblInfo.Anchor = "Bottom,Left,Right"
$lblInfo.BackColor = [System.Drawing.Color]::FromArgb(200, 18, 18, 22)
$lblInfo.ForeColor = $clrText
$lblInfo.TextAlign = "MiddleLeft"
$lblInfo.Padding = New-Object System.Windows.Forms.Padding(10, 0, 10, 0)
$lblInfo.AutoEllipsis = $true
$picPanel.Controls.Add($lblInfo)

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

$btnPrev = New-FlatButton "< PREVIOUS" $clrPanel2
$btnPrev.Location = New-Object System.Drawing.Point(20, 335)
$btnPrev.Size = New-Object System.Drawing.Size(100, 34)
$btnPrev.Anchor = "Bottom,Left"
$form.Controls.Add($btnPrev)

$btnLearnMore = New-FlatButton "LEARN MORE" $clrPanel2
$btnLearnMore.Location = New-Object System.Drawing.Point(130, 335)
$btnLearnMore.Size = New-Object System.Drawing.Size(140, 34)
$btnLearnMore.Anchor = "Bottom,Left"
$btnLearnMore.Enabled = $false
$form.Controls.Add($btnLearnMore)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(280, 340)
$lblStatus.Size = New-Object System.Drawing.Size(126, 24)
$lblStatus.ForeColor = $clrMuted
$lblStatus.TextAlign = "MiddleCenter"
$lblStatus.Anchor = "Bottom,Left"
$form.Controls.Add($lblStatus)

$btnNext = New-FlatButton "NEXT >" $clrAccent
$btnNext.Location = New-Object System.Drawing.Point(430, 335)
$btnNext.Size = New-Object System.Drawing.Size(156, 34)
$btnNext.Anchor = "Bottom,Right"
$form.Controls.Add($btnNext)

$groupBox = New-Object System.Windows.Forms.Panel
$groupBox.Location = New-Object System.Drawing.Point(20, 385)
$groupBox.Size = New-Object System.Drawing.Size(566, 90)
$groupBox.Anchor = "Bottom,Left,Right"
$groupBox.BackColor = $clrPanel
$form.Controls.Add($groupBox)

$lblGroupTitle = New-Object System.Windows.Forms.Label
$lblGroupTitle.Text = "AUTO-REFRESH INTERVAL"
$lblGroupTitle.ForeColor = $clrMuted
$lblGroupTitle.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$lblGroupTitle.Location = New-Object System.Drawing.Point(15, 8)
$lblGroupTitle.Size = New-Object System.Drawing.Size(300, 16)
$groupBox.Controls.Add($lblGroupTitle)

# Days / Hours / Minutes fields, each with a unit label above it, combined
# into one TimeSpan when the schedule is set.
$unitFieldWidth = 60
$unitSpacing    = 70
$unitX          = 15

function New-IntervalUnitField {
    param([string]$LabelText, [int]$X, [int]$Max)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $LabelText
    $lbl.ForeColor = $clrMuted
    $lbl.Location = New-Object System.Drawing.Point($X, 26)
    $lbl.Size = New-Object System.Drawing.Size($unitFieldWidth, 16)
    $groupBox.Controls.Add($lbl)

    $num = New-Object System.Windows.Forms.NumericUpDown
    $num.Location = New-Object System.Drawing.Point($X, 44)
    $num.Size = New-Object System.Drawing.Size($unitFieldWidth, 25)
    $num.Minimum = 0
    $num.Maximum = $Max
    $num.Value = 0
    $num.BackColor = $clrPanel2
    $num.ForeColor = $clrText
    $num.BorderStyle = "FixedSingle"
    $groupBox.Controls.Add($num)
    return $num
}

$numDays    = New-IntervalUnitField -LabelText "Days"    -X ($unitX)                   -Max 3650
$numHours   = New-IntervalUnitField -LabelText "Hours"   -X ($unitX + $unitSpacing)     -Max 23
$numMinutes = New-IntervalUnitField -LabelText "Minutes" -X ($unitX + $unitSpacing * 2) -Max 59
$numMinutes.Value = 1

$buttonsX = $unitX + $unitSpacing * 3

$btnEnable = New-FlatButton "ENABLE" $clrAccent
$btnEnable.Location = New-Object System.Drawing.Point($buttonsX, 42)
$btnEnable.Size = New-Object System.Drawing.Size(85, 28)
$btnEnable.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$groupBox.Controls.Add($btnEnable)

$btnDisable = New-FlatButton "DISABLE" $clrPanel2
$btnDisable.Location = New-Object System.Drawing.Point(($buttonsX + 90), 42)
$btnDisable.Size = New-Object System.Drawing.Size(85, 28)
$btnDisable.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$groupBox.Controls.Add($btnDisable)

$lblSchedule = New-Object System.Windows.Forms.Label
$lblSchedule.Location = New-Object System.Drawing.Point(($buttonsX + 180), 48)
$lblSchedule.Size = New-Object System.Drawing.Size(186, 20)
$lblSchedule.ForeColor = $clrMuted
$lblSchedule.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Italic)
$groupBox.Controls.Add($lblSchedule)

$chkShortcut = New-Object System.Windows.Forms.CheckBox
$chkShortcut.Text = "Show 'Learn More' icon on desktop"
$chkShortcut.ForeColor = $clrText
$chkShortcut.Location = New-Object System.Drawing.Point(20, 485)
$chkShortcut.Size = New-Object System.Drawing.Size(566, 24)
$chkShortcut.Anchor = "Bottom,Left,Right"
$form.Controls.Add($chkShortcut)

$btnDiag = New-FlatButton "RUN DIAGNOSTICS && FIX" $clrPanel2
$btnDiag.Location = New-Object System.Drawing.Point(20, 519)
$btnDiag.Size = New-Object System.Drawing.Size(566, 34)
$btnDiag.Anchor = "Bottom,Left,Right"
$form.Controls.Add($btnDiag)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(20, 563)
$txtLog.Size = New-Object System.Drawing.Size(566, 70)
$txtLog.Anchor = "Bottom,Left,Right"
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 8)
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
    } else {
        $lblSchedule.Text = "Not scheduled"
    }
}

$script:CurrentLearnMoreUrl = $null

function Update-Image($entry) {
    if ($entry -and $entry.Path -and (Test-Path $entry.Path)) {
        if ($script:currentImage) { $script:currentImage.Dispose() }
        $script:currentImage = [System.Drawing.Image]::FromFile($entry.Path)
        $picPanel.Invalidate()
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

$btnLearnMore.Add_Click($openLearnMoreForCurrentImage)

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
    $interval = New-TimeSpan -Days ([int]$numDays.Value) -Hours ([int]$numHours.Value) -Minutes ([int]$numMinutes.Value)

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

$form.Add_Shown({
    if (Sync-AutoRefreshScheduleAction) {
        Append-Log "Updated the existing auto-refresh schedule to run without a console flash."
    }
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

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)

