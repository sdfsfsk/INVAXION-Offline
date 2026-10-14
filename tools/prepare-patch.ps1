# Generate local binaries from an owned game installation and the published delta.
# This function never writes to the game directory.
function Initialize-InvaxionPatch {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$GamePath,
        [Parameter(Mandatory=$true)]$Manifest
    )
    function Get-ByteHash([byte[]]$Bytes) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
    }
    function ConvertFrom-PatchHex([string]$Hex) {
        if ($Hex.Length % 2 -ne 0 -or $Hex -match '[^0-9a-fA-F]') { throw 'Invalid patch hex.' }
        $bytes = New-Object byte[] ($Hex.Length / 2)
        for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16) }
        return ,$bytes
    }
    $originalPath = Join-Path $Root 'original\Assembly-CSharp.dll'
    if (Test-Path -LiteralPath $originalPath) {
        $original = [IO.File]::ReadAllBytes($originalPath)
    } else {
        $installed = Join-Path $GamePath 'INVAXION_Data\Managed\Assembly-CSharp.dll'
        $original = [IO.File]::ReadAllBytes($installed)
        if ((Get-ByteHash $original) -ne $Manifest.original_sha256) {
            throw 'Original game assembly required. Restore it with Steam Verify Files, or provide your verified original backup.'
        }
        [IO.Directory]::CreateDirectory((Split-Path $originalPath -Parent)) | Out-Null
        [IO.File]::WriteAllBytes($originalPath, $original)
    }
    if ((Get-ByteHash $original) -ne $Manifest.original_sha256) { throw 'Original backup checksum mismatch.' }
    foreach ($variant in @('offline', 'autoplay')) {
        $expected = if ($variant -eq 'offline') { $Manifest.patched_sha256 } else { $Manifest.autoplay_sha256 }
        $destination = Join-Path $Root ("bin\Assembly-CSharp.$variant.dll")
        if (Test-Path -LiteralPath $destination) {
            if ((Get-ByteHash ([IO.File]::ReadAllBytes($destination))) -ne $expected) {
                throw "Existing patch checksum mismatch: $destination"
            }
            continue
        }
        $data = [byte[]]$original.Clone()
        $changes = @($Manifest.patches) + @($Manifest.metadata_patches) + @($Manifest.byte_patches)
        if ($variant -eq 'autoplay') {
            $changes += @{ offset=$Manifest.autoplay_patch.offset; new_bytes=$Manifest.autoplay_patch.bytes }
        }
        foreach ($change in $changes) {
            if ($null -eq $change) { continue }
            $bytes = ConvertFrom-PatchHex $change.new_bytes
            $offset = [long]$change.offset
            if ($offset -lt 0 -or $offset + $bytes.Length -gt $data.Length) { throw 'Patch offset is outside the assembly.' }
            [Array]::Copy($bytes, 0, $data, $offset, $bytes.Length)
        }
        if ((Get-ByteHash $data) -ne $expected) { throw "Generated $variant patch checksum mismatch." }
        [IO.Directory]::CreateDirectory((Split-Path $destination -Parent)) | Out-Null
        $temporary = $destination + '.tmp'
        [IO.File]::WriteAllBytes($temporary, $data)
        [IO.File]::Move($temporary, $destination)
        Write-Host "Generated verified local patch: $variant"
    }
}
