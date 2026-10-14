param(
    [ValidateSet('Install','Restore','Launch','Check')][string]$Action = 'Launch',
    [string]$GamePath = '',
    [switch]$Windowed,
    [switch]$Autoplay,
    [switch]$LiveLog
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root 'tools\find-game.ps1')
$GamePath = Find-InvaxionGame -GamePath $GamePath
$manifest = Get-Content -LiteralPath (Join-Path $root 'bin\patch-manifest.json') -Raw | ConvertFrom-Json
. (Join-Path $root 'tools\prepare-patch.ps1')
Initialize-InvaxionPatch -Root $root -GamePath $GamePath -Manifest $manifest
$exe = Join-Path $GamePath 'INVAXION.exe'
$target = Join-Path $GamePath 'INVAXION_Data\Managed\Assembly-CSharp.dll'
$original = Join-Path $root 'original\Assembly-CSharp.dll'
$patched = Join-Path $root 'bin\Assembly-CSharp.offline.dll'
$autoPatched = Join-Path $root 'bin\Assembly-CSharp.autoplay.dll'
function Get-Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
if (!(Test-Path -LiteralPath $exe)) { throw "Game not found: $exe" }
if ((Get-Hash $original) -ne $manifest.original_sha256) { throw 'Original backup checksum mismatch.' }
if ((Get-Hash $patched) -ne $manifest.patched_sha256) { throw 'Offline patch checksum mismatch.' }
if ((Get-Hash $autoPatched) -ne $manifest.autoplay_sha256) { throw 'Autoplay patch checksum mismatch.' }
$current = Get-Hash $target
$knownHashes = @($manifest.original_sha256, $manifest.patched_sha256, $manifest.autoplay_sha256) + @($manifest.compatible_previous_sha256)
if ($current -notin $knownHashes) {
    throw 'Unknown game assembly. Stopped without overwriting it.'
}
if ($Action -eq 'Check') {
    if ($current -eq $manifest.autoplay_sha256) { Write-Output 'PUBLISHER OFFLINE + AUTOPLAY + STEAM ACHIEVEMENTS' }
    elseif ($current -eq $manifest.patched_sha256) { Write-Output 'PUBLISHER OFFLINE + STEAM ACHIEVEMENTS' }
    elseif ($current -eq $manifest.original_sha256) { Write-Output 'ORIGINAL ASSEMBLY INSTALLED' }
    else { Write-Output 'PREVIOUS OFFLINE PATCH INSTALLED - RUN LAUNCH TO UPGRADE' }
    exit 0
}
$running = Get-Process -Name 'INVAXION' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe }
$source = if ($Action -eq 'Restore') { $original } elseif ($Autoplay) { $autoPatched } else { $patched }
$attach = $running -and $Action -eq 'Launch' -and $LiveLog -and $current -eq (Get-Hash $source)
if ($running -and -not $attach) { throw 'Close INVAXION before installing, restoring, or switching its patch variant.' }
if ($current -ne (Get-Hash $source)) {
    $stage = $target + '.offline-stage'
    [IO.File]::Copy($source, $stage, $true)
    [IO.File]::Replace($stage, $target, [NullString]::Value)
}
if ($Action -eq 'Restore') { Write-Output 'Original assembly restored.'; exit 0 }
Write-Output 'Publisher login, gateway and remote downloads are disabled. Steam achievements and statistics are ENABLED.'
Write-Output 'F8: toggle autoplay during a song. F9: turn autoplay off. Escape: pause.'
if ($Action -eq 'Launch') {
    if ($LiveLog) {
        . (Join-Path $root 'tools\debug-session.ps1')
        Start-InvaxionDebugSession -Exe $exe -WorkingDirectory $GamePath -LogDirectory (Join-Path $root 'logs') -Windowed:$Windowed -Attach:$attach -Autoplay:$Autoplay
    } elseif ($Windowed) {
        Start-Process -FilePath $exe -WorkingDirectory $GamePath -ArgumentList '-screen-fullscreen 0 -screen-width 1280 -screen-height 720' -WindowStyle Normal
    } else {
        Start-Process -FilePath $exe -WorkingDirectory $GamePath -WindowStyle Normal
    }
}
