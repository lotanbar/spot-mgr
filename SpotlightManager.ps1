param(
    [switch]$Silent,
    [switch]$Refresh,
    [switch]$ElevatedFix
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
function Get-State {
    if (Test-Path $StatePath) {
        try {
            $s = Get-Content $StatePath -Raw | ConvertFrom-Json
            return [PSCustomObject]@{
                Images = @($s.Images)
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
                $url = $parsed.ad.landscapeImage.asset
                if (-not $url) { continue }

                $md5 = [System.Security.Cryptography.MD5]::Create()
                $hashBytes = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($url))
                $hash = ([BitConverter]::ToString($hashBytes) -replace '-', '').ToLower()
                $dest = Join-Path $CacheDir "$hash.jpg"

                if (-not (Test-Path $dest)) {
                    Invoke-WebRequest -Uri $url -OutFile $dest -TimeoutSec 30
                    Write-Log "Downloaded new image: $hash.jpg"
                }
                $downloaded += $dest
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

if (-not ([System.Management.Automation.PSTypeName]'Native.Chiptune').Type) {
    # Synthesizes an original multi-voice square-wave "scene intro" style
    # stinger (bass pulses + arpeggio + closing chord stab) and writes it
    # to a real WAV file, played through the actual sound device via
    # System.Media.SoundPlayer. Every sample is generated math, not a
    # sourced/ripped recording, so there is zero copyright exposure -
    # nothing is downloaded from YouTube or anywhere else.
    Add-Type -Namespace Native -Name Chiptune -MemberDefinition @"
public static void GenerateWav(string path)
{
    int sampleRate = 44100;
    double duration = 2.6;
    int totalSamples = (int)(sampleRate * duration);
    short[] samples = new short[totalSamples];

    double[,] lead = new double[,] {
        {0.00,392},{0.10,494},{0.20,587},{0.30,784},
        {0.45,587},{0.55,784},{0.65,988},{0.80,1175},
        {1.00,988},{1.10,1175},{1.20,1568}
    };
    double leadNoteLen = 0.09;

    double[] bassTimes = { 0.0, 0.3, 0.6, 0.9, 1.2 };
    double bassFreq = 98.0;
    double bassNoteLen = 0.28;

    double stabStart = 1.5;
    double stabLen = duration - stabStart;
    double[] stabFreqs = { 196, 294, 392, 494 };

    for (int i = 0; i < totalSamples; i++)
    {
        double t = (double)i / sampleRate;
        double val = 0;

        for (int n = 0; n < lead.GetLength(0); n++)
        {
            double start = lead[n, 0];
            double freq = lead[n, 1];
            if (t >= start && t < start + leadNoteLen)
            {
                double lt = t - start;
                double env = System.Math.Exp(-lt * 14);
                double sq = System.Math.Sign(System.Math.Sin(2 * System.Math.PI * freq * lt));
                val += sq * env * 0.22;
            }
        }

        for (int b = 0; b < bassTimes.Length; b++)
        {
            double bstart = bassTimes[b];
            if (t >= bstart && t < bstart + bassNoteLen)
            {
                double lt = t - bstart;
                double env = System.Math.Exp(-lt * 5);
                double sq = System.Math.Sign(System.Math.Sin(2 * System.Math.PI * bassFreq * lt));
                val += sq * env * 0.28;
            }
        }

        if (t >= stabStart && t < stabStart + stabLen)
        {
            double lt = t - stabStart;
            double env = System.Math.Exp(-lt * 2.2);
            double chord = 0;
            for (int f = 0; f < stabFreqs.Length; f++)
            {
                chord += System.Math.Sign(System.Math.Sin(2 * System.Math.PI * stabFreqs[f] * lt));
            }
            chord /= stabFreqs.Length;
            val += chord * env * 0.35;
        }

        if (val > 1) val = 1;
        if (val < -1) val = -1;
        samples[i] = (short)(val * short.MaxValue * 0.9);
    }

    using (System.IO.FileStream fs = new System.IO.FileStream(path, System.IO.FileMode.Create))
    using (System.IO.BinaryWriter bw = new System.IO.BinaryWriter(fs))
    {
        int byteRate = sampleRate * 2;
        int dataSize = samples.Length * 2;
        bw.Write(System.Text.Encoding.ASCII.GetBytes("RIFF"));
        bw.Write(36 + dataSize);
        bw.Write(System.Text.Encoding.ASCII.GetBytes("WAVE"));
        bw.Write(System.Text.Encoding.ASCII.GetBytes("fmt "));
        bw.Write(16);
        bw.Write((short)1);
        bw.Write((short)1);
        bw.Write(sampleRate);
        bw.Write(byteRate);
        bw.Write((short)2);
        bw.Write((short)16);
        bw.Write(System.Text.Encoding.ASCII.GetBytes("data"));
        bw.Write(dataSize);
        for (int i = 0; i < samples.Length; i++) bw.Write(samples[i]);
    }
}

public static void PlayIntroJingleAsync()
{
    try
    {
        string dir = System.IO.Path.Combine(
            System.Environment.GetFolderPath(System.Environment.SpecialFolder.LocalApplicationData),
            "SpotlightManager");
        System.IO.Directory.CreateDirectory(dir);
        string wavPath = System.IO.Path.Combine(dir, "intro.wav");
        if (!System.IO.File.Exists(wavPath))
        {
            GenerateWav(wavPath);
        }
        System.Media.SoundPlayer player = new System.Media.SoundPlayer(wavPath);
        player.Play();
    }
    catch { }
}
"@
}

# -----------------------------------------------------------------
# Startup jingle - see Native.Chiptune above for how it is generated.
# -----------------------------------------------------------------
function Start-IntroJingle {
    try {
        [Native.Chiptune]::PlayIntroJingleAsync()
    } catch {
        Write-Log "Intro jingle failed to play: $($_.Exception.Message)"
    }
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
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $Minutes) -RepetitionDuration ([TimeSpan]::MaxValue)
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
        return $trig.Repetition.Interval
    } catch { return $null }
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
            foreach ($p in $new) {
                if ($existing -notcontains $p) { $existing += $p }
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

    $path = $state.Images[$state.Index]
    if (-not (Test-Path $path)) {
        Write-Log "Cached image missing on disk, removing from list: $path"
        $state.Images = @($state.Images | Where-Object { $_ -ne $path })
        if ($state.Index -ge $state.Images.Count) { $state.Index = $state.Images.Count - 1 }
        Save-State $state
        return $null
    }

    Set-DesktopWallpaper -Path $path | Out-Null
    Save-State $state
    return $path
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
# GUI - dark theme
# ============================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$clrBg      = [System.Drawing.Color]::FromArgb(255, 18, 18, 22)
$clrPanel   = [System.Drawing.Color]::FromArgb(255, 30, 30, 36)
$clrPanel2  = [System.Drawing.Color]::FromArgb(255, 40, 40, 48)
$clrAccent  = [System.Drawing.Color]::FromArgb(255, 130, 90, 255)
$clrAccent2 = [System.Drawing.Color]::FromArgb(255, 100, 65, 220)
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
$form.Size = New-Object System.Drawing.Size(600, 610)
$form.MinimumSize = New-Object System.Drawing.Size(600, 610)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "Sizable"
$form.MaximizeBox = $true
$form.MinimizeBox = $true
$form.BackColor = $clrBg
$form.ForeColor = $clrText
$form.Font = $fontMain
$form.KeyPreview = $true

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
$picPanel.Size = New-Object System.Drawing.Size(546, 260)
$picPanel.Anchor = "Top,Left,Right,Bottom"
$picPanel.BackColor = [System.Drawing.Color]::Black
$form.Controls.Add($picPanel)

# Custom "cover" draw (crop-to-fill, no letterboxing) so the preview
# mirrors exactly how Windows itself renders a Fill-style wallpaper,
# instead of PictureBox's Zoom mode which pads with black bars.
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

$btnPrev = New-FlatButton "< PREVIOUS" $clrPanel2
$btnPrev.Location = New-Object System.Drawing.Point(20, 325)
$btnPrev.Size = New-Object System.Drawing.Size(120, 34)
$btnPrev.Anchor = "Bottom,Left"
$form.Controls.Add($btnPrev)

$btnNext = New-FlatButton "NEXT >" $clrAccent
$btnNext.Location = New-Object System.Drawing.Point(446, 325)
$btnNext.Size = New-Object System.Drawing.Size(120, 34)
$btnNext.Anchor = "Bottom,Right"
$form.Controls.Add($btnNext)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.ForeColor = $clrMuted
$lblStatus.Location = New-Object System.Drawing.Point(20, 365)
$lblStatus.Size = New-Object System.Drawing.Size(546, 20)
$lblStatus.TextAlign = "MiddleCenter"
$lblStatus.Anchor = "Bottom,Left,Right"
$form.Controls.Add($lblStatus)

$groupBox = New-Object System.Windows.Forms.Panel
$groupBox.Location = New-Object System.Drawing.Point(20, 395)
$groupBox.Size = New-Object System.Drawing.Size(546, 70)
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

$numInterval = New-Object System.Windows.Forms.NumericUpDown
$numInterval.Location = New-Object System.Drawing.Point(15, 32)
$numInterval.Size = New-Object System.Drawing.Size(60, 25)
$numInterval.Minimum = 1
$numInterval.Maximum = 999
$numInterval.Value = 1
$numInterval.BackColor = $clrPanel2
$numInterval.ForeColor = $clrText
$numInterval.BorderStyle = "FixedSingle"
$groupBox.Controls.Add($numInterval)

$cmbUnit = New-Object System.Windows.Forms.ComboBox
$cmbUnit.Location = New-Object System.Drawing.Point(85, 32)
$cmbUnit.Size = New-Object System.Drawing.Size(95, 25)
$cmbUnit.DropDownStyle = "DropDownList"
$cmbUnit.FlatStyle = "Flat"
$cmbUnit.BackColor = $clrPanel2
$cmbUnit.ForeColor = $clrText
$cmbUnit.Items.AddRange(@("Minutes", "Hours", "Days"))
$cmbUnit.SelectedIndex = 1
$groupBox.Controls.Add($cmbUnit)

$btnEnable = New-FlatButton "ENABLE" $clrAccent
$btnEnable.Location = New-Object System.Drawing.Point(195, 30)
$btnEnable.Size = New-Object System.Drawing.Size(85, 28)
$btnEnable.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$groupBox.Controls.Add($btnEnable)

$btnDisable = New-FlatButton "DISABLE" $clrPanel2
$btnDisable.Location = New-Object System.Drawing.Point(290, 30)
$btnDisable.Size = New-Object System.Drawing.Size(85, 28)
$btnDisable.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$groupBox.Controls.Add($btnDisable)

$lblSchedule = New-Object System.Windows.Forms.Label
$lblSchedule.Location = New-Object System.Drawing.Point(390, 36)
$lblSchedule.Size = New-Object System.Drawing.Size(145, 20)
$lblSchedule.ForeColor = $clrMuted
$lblSchedule.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Italic)
$groupBox.Controls.Add($lblSchedule)

$btnDiag = New-FlatButton "RUN DIAGNOSTICS && FIX" $clrPanel2
$btnDiag.Location = New-Object System.Drawing.Point(20, 475)
$btnDiag.Size = New-Object System.Drawing.Size(546, 34)
$btnDiag.Anchor = "Bottom,Left,Right"
$form.Controls.Add($btnDiag)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(20, 518)
$txtLog.Size = New-Object System.Drawing.Size(546, 55)
$txtLog.Anchor = "Bottom,Left,Right"
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.BackColor = $clrPanel
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(255, 140, 220, 150)
$txtLog.BorderStyle = "FixedSingle"
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

function Update-Image($path) {
    if ($path -and (Test-Path $path)) {
        if ($script:currentImage) { $script:currentImage.Dispose() }
        $script:currentImage = [System.Drawing.Image]::FromFile($path)
        $picPanel.Invalidate()
        $state = Get-State
        $lblStatus.Text = "Image $($state.Index + 1) of $($state.Images.Count)"
    } else {
        $lblStatus.Text = "No image available"
    }
}

$btnNext.Add_Click({
    $btnNext.Enabled = $false; $btnPrev.Enabled = $false
    $form.Cursor = "WaitCursor"
    try {
        $path = Move-SpotlightImage -Direction "Next"
        Update-Image $path
        if (-not $path) { Append-Log "Could not fetch/display a new image. Check log.txt for details." }
    } finally {
        $form.Cursor = "Default"
        $btnNext.Enabled = $true; $btnPrev.Enabled = $true
    }
})

$btnPrev.Add_Click({
    $btnPrev.Enabled = $false; $btnNext.Enabled = $false
    $form.Cursor = "WaitCursor"
    try {
        $path = Move-SpotlightImage -Direction "Previous"
        Update-Image $path
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

$form.Add_Shown({
    Start-IntroJingle
    Refresh-ScheduleLabel
    $state = Get-State
    if ($state.Images.Count -gt 0 -and $state.Index -ge 0) {
        Update-Image $state.Images[$state.Index]
    } else {
        Append-Log "No cached images yet. Click 'Next' to fetch the first one."
    }
})

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
