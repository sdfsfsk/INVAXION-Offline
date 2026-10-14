$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'prepare-patch.ps1')
$manifest = Get-Content -LiteralPath (Join-Path $project 'bin\patch-manifest.json') -Raw | ConvertFrom-Json
$qaRoot = [IO.Path]::GetFullPath((Join-Path $project 'qa'))
$fixtureRoot = Join-Path $qaRoot ('prepare-test-' + [Guid]::NewGuid().ToString('N'))
$checks = New-Object 'System.Collections.Generic.List[string]'
function Assert-Test([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "Failed: $Name" }
    $checks.Add($Name)
}
function Expect-Failure([scriptblock]$Action, [string]$Message, [string]$Name) {
    $caught = $false
    try { & $Action } catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        $caught = $true
    }
    Assert-Test $caught $Name
}
try {
    $game = Join-Path $fixtureRoot 'game'
    $managed = Join-Path $game 'INVAXION_Data\Managed'
    [IO.Directory]::CreateDirectory($managed) | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $game 'INVAXION.exe'), [byte[]]@())
    $target = Join-Path $managed 'Assembly-CSharp.dll'
    Copy-Item -LiteralPath (Join-Path $project 'original\Assembly-CSharp.dll') -Destination $target
    $clone = Join-Path $fixtureRoot 'clone'
    [IO.Directory]::CreateDirectory((Join-Path $clone 'tools')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $clone 'bin')) | Out-Null
    Copy-Item -LiteralPath (Join-Path $project 'offline.ps1') -Destination $clone
    foreach ($name in @('find-game.ps1', 'prepare-patch.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $clone 'tools')
    }
    Copy-Item -LiteralPath (Join-Path $project 'bin\patch-manifest.json') -Destination (Join-Path $clone 'bin')
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $clone 'offline.ps1') -Action Check -GamePath $game
    Assert-Test ($LASTEXITCODE -eq 0) 'fresh source checkout prepares patches without Python'
    Assert-Test ((Get-FileHash -LiteralPath $target).Hash.ToLowerInvariant() -eq $manifest.original_sha256) 'Check leaves installed game untouched'
    foreach ($pair in @(@('offline', $manifest.patched_sha256), @('autoplay', $manifest.autoplay_sha256))) {
        $generated = Join-Path $clone ("bin\Assembly-CSharp.$($pair[0]).dll")
        Assert-Test ((Get-FileHash -LiteralPath $generated).Hash.ToLowerInvariant() -eq $pair[1]) ("generated hash: " + $pair[0])
    }
    Initialize-InvaxionPatch -Root $clone -GamePath $game -Manifest $manifest
    Assert-Test $true 'existing valid outputs are reusable'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $clone 'offline.ps1') -Action Install -Autoplay -GamePath $game
    Assert-Test ($LASTEXITCODE -eq 0 -and (Get-FileHash -LiteralPath $target).Hash.ToLowerInvariant() -eq $manifest.autoplay_sha256) 'install applies validated autoplay to fixture'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $clone 'offline.ps1') -Action Restore -GamePath $game
    Assert-Test ($LASTEXITCODE -eq 0 -and (Get-FileHash -LiteralPath $target).Hash.ToLowerInvariant() -eq $manifest.original_sha256) 'restore recovers exact original fixture'
    $badRoot = Join-Path $fixtureRoot 'unknown'
    [IO.File]::WriteAllBytes($target, [byte[]]@(1, 2, 3))
    Expect-Failure { Initialize-InvaxionPatch -Root $badRoot -GamePath $game -Manifest $manifest } 'Original game assembly required' 'unknown original rejected'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $badRoot 'original\Assembly-CSharp.dll'))) 'unknown original never backed up as trusted'
    $badPatch = Join-Path $clone 'bin\Assembly-CSharp.offline.dll'
    [IO.File]::WriteAllBytes($badPatch, [byte[]]@(1, 2, 3))
    Expect-Failure { Initialize-InvaxionPatch -Root $clone -GamePath $game -Manifest $manifest } 'Existing patch checksum mismatch' 'corrupt local patch rejected'
    $report = [ordered]@{ result='PASS'; count=$checks.Count; cases=@($checks) }
    $report | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $qaRoot 'prepare-patch-tests.json') -Encoding UTF8
    $report | ConvertTo-Json
} finally {
    # Only remove this test's unique directory within the project's qa folder.
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolvedFixture = (Resolve-Path -LiteralPath $fixtureRoot).Path
        if (-not $resolvedFixture.StartsWith($qaRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to clean a test directory outside qa.'
        }
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
