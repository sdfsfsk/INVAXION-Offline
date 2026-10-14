# Dot-sourced by offline.ps1. Uses Windows PowerShell/.NET only.
function Start-InvaxionDebugSession {
    param(
        [Parameter(Mandatory=$true)][string]$Exe,
        [Parameter(Mandatory=$true)][string]$WorkingDirectory,
        [Parameter(Mandatory=$true)][string]$LogDirectory,
        [switch]$Windowed,
        [switch]$Attach,
        [switch]$Autoplay
    )
    $ErrorActionPreference = 'Stop'
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $utf8
    if (-not ('InvaxionDebug.LiveLogReader' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'LiveLogReader.cs')
    }
    [IO.Directory]::CreateDirectory($LogDirectory) | Out-Null
    $mode = if ($Autoplay) { 'autoplay' } else { 'manual' }
    $archive = Join-Path $LogDirectory ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + $mode + '.log')
    $writer = New-Object IO.StreamWriter($archive, $false, $utf8)
    $writer.AutoFlush = $true
    $source = Join-Path $WorkingDirectory 'INVAXION_Data\output_log.txt'
    $reader = New-Object InvaxionDebug.LiveLogReader($source)
    $initialLog = Get-Item -LiteralPath $source -ErrorAction SilentlyContinue
    $initialWrite = if ($initialLog) { $initialLog.LastWriteTimeUtc.Ticks } else { 0L }
    $waitingForFreshLog = -not $Attach
    $seen = @{}
    $active = @{}
    $ready = $false
    $hadProcess = $false
    $emptySince = $null
    $sessionStart = [DateTime]::UtcNow
    $sessionInfo = [ordered]@{
        started_utc = $sessionStart.ToString('o')
        executable = $Exe
        source_log = $source
        session_log = $archive
        attached = [bool]$Attach
        autoplay = [bool]$Autoplay
        process_ids = @()
        status = 'starting'
    }
    $statePath = Join-Path $LogDirectory 'last-debug-session.json'

    function Save-DebugState {
        [IO.File]::WriteAllText($statePath, ($sessionInfo | ConvertTo-Json -Depth 4), $utf8)
    }
    function Write-DebugLine([string]$Line, [string]$Kind = 'game') {
        $writer.WriteLine($Line)
        if ($Kind -eq 'status') { Write-Host $Line -ForegroundColor Cyan }
        elseif ($Line -match '(?i)exception|error|failed|崩溃|失败') { Write-Host $Line -ForegroundColor Red }
        elseif ($Line -match '(?i)warning|警告') { Write-Host $Line -ForegroundColor Yellow }
        else { Write-Host $Line }
    }
    function Write-AvailableGameLog {
        foreach ($line in $reader.ReadAvailable()) {
            if ($line -match 'PC_newQuickPlayView|=== GameStart') { $script:invaxionLogReady = $true }
            Write-DebugLine $line
        }
        if ($reader.Reopened) {
            Write-DebugLine '[DEBUG] Game log was rewritten; reading the new log from its beginning.' 'status'
        }
    }

    $script:invaxionLogReady = $false
    try {
        Write-DebugLine '[DEBUG] INVAXION live game log / Steam achievements enabled' 'status'
        Write-DebugLine ('[DEBUG] Game: ' + $Exe) 'status'
        Write-DebugLine ('[DEBUG] Source: ' + $source) 'status'
        Write-DebugLine ('[DEBUG] Saved session: ' + $archive) 'status'
        Write-DebugLine '[DEBUG] F8: autoplay on/off. F9: autoplay off. Esc: pause game.' 'status'
        Write-DebugLine '[DEBUG] Closing this console stops logging; it does not stop the game.' 'status'
        Save-DebugState
        if ($Attach) {
            Write-DebugLine '[DEBUG] Attaching to the running game; showing its current log from the beginning.' 'status'
        } else {
            $launch = @{ FilePath=$Exe; WorkingDirectory=$WorkingDirectory; WindowStyle='Normal'; PassThru=$true }
            if ($Windowed) { $launch.ArgumentList = '-screen-fullscreen 0 -screen-width 1280 -screen-height 720' }
            $startedProcess = Start-Process @launch
            Write-DebugLine ('[DEBUG] Started process ' + $startedProcess.Id + '; waiting for Unity / Steam.') 'status'
        }

        while ($true) {
            $now = [DateTime]::UtcNow
            $current = @(Get-Process -Name 'INVAXION' -ErrorAction SilentlyContinue | Where-Object {
                try { $_.Path -eq $Exe } catch { $false }
            })
            $newActive = @{}
            foreach ($process in $current) {
                try { $identity = '{0}:{1}' -f $process.Id, $process.StartTime.ToUniversalTime().Ticks }
                catch { continue }
                $newActive[$identity] = $process.Id
                if (-not $seen.ContainsKey($identity)) {
                    if ($hadProcess) {
                        $reader.Reset()
                        $ready = $false
                        $script:invaxionLogReady = $false
                        Write-DebugLine '[DEBUG] Steam/new game process detected; continuing log capture.' 'status'
                    }
                    $seen[$identity] = $process.Id
                    $sessionInfo.process_ids += $process.Id
                    $sessionInfo.status = 'running'
                    $hadProcess = $true
                    Write-DebugLine ('[DEBUG] Tracking game PID ' + $process.Id) 'status'
                    Save-DebugState
                }
            }
            $active = $newActive
            if ($waitingForFreshLog) {
                $info = Get-Item -LiteralPath $source -ErrorAction SilentlyContinue
                if ($info -and $info.LastWriteTimeUtc.Ticks -ne $initialWrite) {
                    $waitingForFreshLog = $false
                }
            }
            if (-not $waitingForFreshLog) { Write-AvailableGameLog }
            $ready = $ready -or $script:invaxionLogReady

            if ($active.Count -gt 0) { $emptySince = $null }
            elseif (-not $hadProcess) {
                if (($now - $sessionStart).TotalSeconds -ge 120) {
                    throw 'No game process appeared within 120 seconds. Check the log above and Steam.'
                }
            } else {
                if ($null -eq $emptySince) {
                    $emptySince = $now
                    $message = if ($ready) { '[DEBUG] Game exited; collecting the last log lines.' }
                        else { '[DEBUG] Startup process exited; waiting up to 45 seconds for Steam to relaunch the game.' }
                    Write-DebugLine $message 'status'
                }
                $grace = if ($ready) { 2 } else { 45 }
                if (($now - $emptySince).TotalSeconds -ge $grace) { break }
            }
            Start-Sleep -Milliseconds 200
        }
        if (-not $waitingForFreshLog) { Write-AvailableGameLog }
        $last = $reader.Finish()
        if ($last.Length -gt 0) { Write-DebugLine $last }
        if (-not $ready) { throw 'Game exited before reaching the menu. See the saved session log.' }
        $sessionInfo.status = 'exited'
        Write-DebugLine ('[DEBUG] Game session ended. Log saved: ' + $archive) 'status'
    } catch {
        $sessionInfo.status = 'error'
        Write-DebugLine ('[DEBUG ERROR] ' + $_.Exception.Message)
        throw
    } finally {
        if ($sessionInfo.status -eq 'running' -or $sessionInfo.status -eq 'starting') {
            $sessionInfo.status = 'logger_stopped'
        }
        $sessionInfo.ended_utc = [DateTime]::UtcNow.ToString('o')
        Save-DebugState
        $writer.Dispose()
        Remove-Variable -Name invaxionLogReady -Scope Script -ErrorAction SilentlyContinue
    }
}
