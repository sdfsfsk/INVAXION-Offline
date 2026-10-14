function Find-InvaxionGame {
    param([string]$GamePath)
    if ($GamePath) {
        $resolved = (Resolve-Path -LiteralPath $GamePath).Path
        if (-not (Test-Path -LiteralPath (Join-Path $resolved 'INVAXION.exe'))) {
            throw "INVAXION.exe not found in: $resolved"
        }
        return $resolved
    }
    $roots = @()
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
        $entry = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($entry.SteamPath) { $roots += $entry.SteamPath }
        if ($entry.InstallPath) { $roots += $entry.InstallPath }
    }
    if (${env:ProgramFiles(x86)}) { $roots += (Join-Path ${env:ProgramFiles(x86)} 'Steam') }
    $libraries = @($roots)
    foreach ($steam in $roots) {
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            $text = Get-Content -LiteralPath $vdf -Raw -Encoding UTF8
            foreach ($match in [regex]::Matches($text, '"path"\s*"([^"]+)"')) {
                $libraries += $match.Groups[1].Value.Replace('\\', '\')
            }
        }
    }
    foreach ($library in ($libraries | Select-Object -Unique)) {
        $acf = Join-Path $library 'steamapps\appmanifest_921630.acf'
        if (-not (Test-Path -LiteralPath $acf)) { continue }
        $text = Get-Content -LiteralPath $acf -Raw -Encoding UTF8
        $directory = [regex]::Match($text, '"installdir"\s*"([^"]+)"')
        if ($directory.Success) {
            $candidate = Join-Path (Join-Path $library 'steamapps\common') $directory.Groups[1].Value
            if (Test-Path -LiteralPath (Join-Path $candidate 'INVAXION.exe')) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        }
    }
    throw 'INVAXION was not found in Steam libraries. Specify -GamePath "path to game".'
}
