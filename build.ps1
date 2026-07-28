param([switch]$DebugBuild)

$src = Join-Path $PSScriptRoot "SpotlightManager.ps1"

# Zip up the tracked repo (source + full git history, via .git) so it can be
# embedded in the exe and recovered later with -ExportSource. Only meaningful
# if there's actually a git repo here and it's committed - working tree must
# be clean, otherwise the embedded snapshot would silently miss your latest
# edits.
function Get-EmbeddedRepoZipBase64 {
    $gitDir = Join-Path $PSScriptRoot ".git"
    if (-not (Test-Path $gitDir)) {
        Write-Warning "No .git folder found at $PSScriptRoot - building without embedded source."
        return $null
    }
    $status = git -C $PSScriptRoot status --porcelain
    if ($status) {
        Write-Warning "Working tree has uncommitted changes - the embedded source snapshot will NOT include them. Commit first if you want them included."
    }

    $zipPath = Join-Path $env:TEMP "SpotlightManager-repo-embed.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    $items = Get-ChildItem -Path $PSScriptRoot -Force | Where-Object { $_.Extension -ne ".exe" }
    Compress-Archive -Path $items.FullName -DestinationPath $zipPath -CompressionLevel Optimal
    $bytes = [System.IO.File]::ReadAllBytes($zipPath)
    Remove-Item $zipPath -Force
    return [Convert]::ToBase64String($bytes)
}

$repoZipBase64 = Get-EmbeddedRepoZipBase64

function New-BuildCopy {
    param([string]$OutputPs1Path, [bool]$AsDebugBuild)

    $content = Get-Content $src -Raw
    if ($AsDebugBuild) {
        $content = $content -replace '\$Script:IsDebugBuild = \$false', '$Script:IsDebugBuild = $true'
    }
    if ($repoZipBase64) {
        $content = $content -replace '\$Script:EmbeddedRepoZipBase64 = \$null', "`$Script:EmbeddedRepoZipBase64 = '$repoZipBase64'"
    }
    Set-Content -Path $OutputPs1Path -Value $content -Encoding UTF8
}

if ($DebugBuild) {
    $tmp = Join-Path $env:TEMP "SpotlightManager.DebugBuild.ps1"
    New-BuildCopy -OutputPs1Path $tmp -AsDebugBuild $true
    $out = Join-Path $PSScriptRoot "SpotlightManager.Debug.exe"
    Invoke-ps2exe -inputFile $tmp -outputFile $out -noConsole -title "Spotlight Manager (DEBUG)" -description "Fixes and manages Windows Spotlight images (debug build - seconds interval)"
    Remove-Item $tmp -Force
} else {
    $tmp = Join-Path $env:TEMP "SpotlightManager.Build.ps1"
    New-BuildCopy -OutputPs1Path $tmp -AsDebugBuild $false
    $out = Join-Path $PSScriptRoot "SpotlightManager.exe"
    Invoke-ps2exe -inputFile $tmp -outputFile $out -noConsole -title "Spotlight Manager" -description "Fixes and manages Windows Spotlight images"
    Remove-Item $tmp -Force
}
