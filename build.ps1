param([switch]$DebugBuild)

$src = Join-Path $PSScriptRoot "SpotlightManager.ps1"

if ($DebugBuild) {
    $tmp = Join-Path $env:TEMP "SpotlightManager.DebugBuild.ps1"
    (Get-Content $src -Raw) -replace '\$Script:IsDebugBuild = \$false', '$Script:IsDebugBuild = $true' | Set-Content -Path $tmp -Encoding UTF8
    $out = Join-Path $PSScriptRoot "SpotlightManager.Debug.exe"
    Invoke-ps2exe -inputFile $tmp -outputFile $out -noConsole -title "Spotlight Manager (DEBUG)" -description "Fixes and manages Windows Spotlight images (debug build - seconds interval)"
    Remove-Item $tmp -Force
} else {
    $out = Join-Path $PSScriptRoot "SpotlightManager.exe"
    Invoke-ps2exe -inputFile $src -outputFile $out -noConsole -title "Spotlight Manager" -description "Fixes and manages Windows Spotlight images"
}
