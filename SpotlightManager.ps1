param(
    [switch]$Silent,
    [switch]$Refresh,
    [switch]$ElevatedFix,
    [switch]$OpenLearnMore
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
function Set-AutoRefreshSchedule {
    param([int]$Minutes)

    try {
        $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

        $action = New-ScheduledTaskAction -Execute $exePath -Argument "-Silent -Refresh"
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $Minutes) -RepetitionDuration (New-TimeSpan -Days 3650)
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description "Rotates the desktop Spotlight image on an interval." | Out-Null
        Write-Log "Auto-refresh scheduled every $Minutes minute(s)."
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
$form.Text = "Spotlight Manager"
$form.Size = New-Object System.Drawing.Size(560, 550)
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
$groupBox.Size = New-Object System.Drawing.Size(530, 60)
$form.Controls.Add($groupBox)

$numInterval = New-Object System.Windows.Forms.NumericUpDown
$numInterval.Location = New-Object System.Drawing.Point(15, 25)
$numInterval.Size = New-Object System.Drawing.Size(70, 25)
$numInterval.Minimum = 1
$numInterval.Maximum = 999
$numInterval.Value = 1
$groupBox.Controls.Add($numInterval)

$cmbUnit = New-Object System.Windows.Forms.ComboBox
$cmbUnit.Location = New-Object System.Drawing.Point(95, 25)
$cmbUnit.Size = New-Object System.Drawing.Size(100, 25)
$cmbUnit.DropDownStyle = "DropDownList"
$cmbUnit.Items.AddRange(@("Minutes", "Hours", "Days"))
$cmbUnit.SelectedIndex = 1
$groupBox.Controls.Add($cmbUnit)

$btnEnable = New-Object System.Windows.Forms.Button
$btnEnable.Text = "Enable"
$btnEnable.Location = New-Object System.Drawing.Point(210, 23)
$btnEnable.Size = New-Object System.Drawing.Size(90, 28)
$groupBox.Controls.Add($btnEnable)

$btnDisable = New-Object System.Windows.Forms.Button
$btnDisable.Text = "Disable"
$btnDisable.Location = New-Object System.Drawing.Point(310, 23)
$btnDisable.Size = New-Object System.Drawing.Size(90, 28)
$groupBox.Controls.Add($btnDisable)

$lblSchedule = New-Object System.Windows.Forms.Label
$lblSchedule.Location = New-Object System.Drawing.Point(410, 28)
$lblSchedule.Size = New-Object System.Drawing.Size(115, 20)
$lblSchedule.Font = New-Object System.Drawing.Font($lblSchedule.Font, [System.Drawing.FontStyle]::Italic)
$groupBox.Controls.Add($lblSchedule)

$chkShortcut = New-Object System.Windows.Forms.CheckBox
$chkShortcut.Text = "Show 'Learn More' icon on desktop"
$chkShortcut.Location = New-Object System.Drawing.Point(15, 355)
$chkShortcut.Size = New-Object System.Drawing.Size(530, 24)
$form.Controls.Add($chkShortcut)

$btnDiag = New-Object System.Windows.Forms.Button
$btnDiag.Text = "Run Diagnostics && Fix"
$btnDiag.Location = New-Object System.Drawing.Point(15, 385)
$btnDiag.Size = New-Object System.Drawing.Size(530, 30)
$form.Controls.Add($btnDiag)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(15, 425)
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
    $interval = Get-AutoRefreshSchedule
    if ($interval) {
        $lblSchedule.Text = "Active: every $([int]$interval.TotalMinutes) min"
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
    $minutes = switch ($cmbUnit.SelectedItem) {
        "Minutes" { [int]$numInterval.Value }
        "Hours"   { [int]$numInterval.Value * 60 }
        "Days"    { [int]$numInterval.Value * 60 * 24 }
    }
    if (Set-AutoRefreshSchedule -Minutes $minutes) {
        Append-Log "Auto-refresh enabled: every $($numInterval.Value) $($cmbUnit.SelectedItem)."
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

