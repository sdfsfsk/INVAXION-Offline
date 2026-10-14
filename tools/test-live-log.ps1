$ErrorActionPreference = 'Stop'
if (-not ('InvaxionDebug.LiveLogReader' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'LiveLogReader.cs')
}
$fixture = Join-Path (Split-Path $PSScriptRoot -Parent) 'qa\live-log-fixture.txt'
[IO.Directory]::CreateDirectory((Split-Path $fixture -Parent)) | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
$checks = New-Object 'System.Collections.Generic.List[string]'
function Assert-Lines([string[]]$Actual, [string[]]$Expected, [string]$Case) {
    if ($Actual.Count -ne $Expected.Count -or [string]::Join('|', $Actual) -cne [string]::Join('|', $Expected)) {
        throw "Failed ${Case}: $($Actual -join '|')"
    }
    $checks.Add($Case)
}
function Append-Bytes([byte[]]$Bytes) {
    $stream = New-Object IO.FileStream($fixture, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    try { $stream.Write($Bytes, 0, $Bytes.Length) } finally { $stream.Dispose() }
}
$content = $utf8.GetBytes("音灵中文`r`n")
[IO.File]::WriteAllBytes($fixture, [byte[]]$content[0..1])
$reader = New-Object InvaxionDebug.LiveLogReader($fixture)
Assert-Lines -Actual @($reader.ReadAvailable()) -Expected @() -Case 'incomplete UTF-8 bytes wait'
Append-Bytes ([byte[]]$content[2..($content.Length-1)])
Assert-Lines -Actual @($reader.ReadAvailable()) -Expected @('音灵中文') -Case 'UTF-8 continuation and CRLF'
Assert-Lines -Actual @($reader.ReadAvailable()) -Expected @() -Case 'no duplicate lines at EOF'
Append-Bytes ($utf8.GetBytes('未写完'))
Assert-Lines -Actual @($reader.ReadAvailable()) -Expected @() -Case 'partial line waits'
Append-Bytes ($utf8.GetBytes("日志`n"))
Assert-Lines -Actual @($reader.ReadAvailable()) -Expected @('未写完日志') -Case 'partial line continuation'
$rewrite = 'Steam 重启后已经写入较长的新日志，文件长度超过旧读取位置。'
[IO.File]::WriteAllText($fixture, $rewrite+"`n", $utf8)
Assert-Lines -Actual @($reader.ReadAvailable()) -Expected @($rewrite) -Case 'rewrite beyond old cursor'
if (-not $reader.Reopened) { throw 'Rewrite marker missing' }
[IO.File]::WriteAllText($fixture, '', $utf8)
Assert-Lines -Actual @($reader.ReadAvailable()) -Expected @() -Case 'truncate to empty'
Append-Bytes ($utf8.GetBytes("新日志`n最后一行"))
Assert-Lines -Actual @($reader.ReadAvailable()) -Expected @('新日志') -Case 'read after truncate'
Assert-Lines -Actual @($reader.Finish()) -Expected @('最后一行') -Case 'flush last line without newline'
$reader.Reset()
Assert-Lines -Actual @($reader.ReadAvailable()) -Expected @('新日志') -Case 'process handoff resets cursor'
$report = [ordered]@{ result='PASS'; cases=@($checks); count=$checks.Count }
[IO.File]::WriteAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'qa\live-log-tests.json'), ($report | ConvertTo-Json), $utf8)
Write-Output ($report | ConvertTo-Json)
