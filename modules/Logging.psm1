# The crash and error log (spec section 4): one line per entry in logs\srrvrr-YYYY-MM-DD.log (local date), the
# same error at most once a minute with a count of repeats, and a daily size cap that flags and the final
# "stopped" line still get past. Only the main thread writes; the samplers report through the shared state.

# "2026-01-05T23:59:00.000-06:00 ERROR fast-sampler: message", one line, newlines escaped.
function Format-LogLine {
    param([DateTimeOffset]$Time, [ValidateSet('INFO', 'WARN', 'ERROR', 'FLAG')][string]$Level, [string]$Source, [string]$Message)
    $text = $Message -replace "`r`n|`r|`n", '\n'
    '{0} {1} {2}: {3}' -f $Time.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz', [Globalization.CultureInfo]::InvariantCulture), $Level, $Source, $text
}

# Everything worth knowing about an error that stopped something: type and message, where in which script, the
# script's call stack, and each inner exception.
function Format-SrrException {
    param([Management.Automation.ErrorRecord]$ErrorRecord)
    $e = $ErrorRecord.Exception
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add("$($e.GetType().FullName): $($e.Message)")
    $info = $ErrorRecord.InvocationInfo
    if ($info -and $info.ScriptName) { $parts.Add("at $([IO.Path]::GetFileName($info.ScriptName)):$($info.ScriptLineNumber)") }
    if ($ErrorRecord.ScriptStackTrace) { $parts.Add("stack: $($ErrorRecord.ScriptStackTrace)") }
    $inner = $e.InnerException
    while ($inner) { $parts.Add("inner: $($inner.GetType().FullName): $($inner.Message)"); $inner = $inner.InnerException }
    $parts -join ' | '
}

# The same error at most once per window. ShouldWrite(key) returns 0 (write it, no repeats since), the number of
# repeats to mention (write it with "(repeated N times)"), or $null (don't write it). Flush() returns the repeat
# counts still waiting, for the stop path to write.
function New-ErrorThrottle {
    param([Parameter(Mandatory)][scriptblock]$Clock, [int]$WindowSeconds = 60)
    $t = [pscustomobject]@{ Clock = $Clock; Window = [TimeSpan]::FromSeconds($WindowSeconds); Seen = @{} }
    $t | Add-Member ScriptMethod ShouldWrite {
        param([string]$Key)
        $now = & $this.Clock
        $s = $this.Seen[$Key]
        if (-not $s) { $this.Seen[$Key] = @{ Last = $now; Repeats = 0 }; return 0 }
        if ($now - $s.Last -lt $this.Window) { $s.Repeats++; return $null }
        $n = $s.Repeats
        $s.Last = $now; $s.Repeats = 0
        $n
    }
    $t | Add-Member ScriptMethod Flush {
        $out = @{}
        foreach ($k in @($this.Seen.Keys)) { if ($this.Seen[$k].Repeats) { $out[$k] = $this.Seen[$k].Repeats; $this.Seen[$k].Repeats = 0 } }
        $out
    }
    $t
}

# A log file per local date, Folder\Prefix-YYYY-MM-DD.Extension. Write(line, always) appends one line. Once a day's
# file reaches CapBytes, one "daily size cap reached" line is written and later lines are dropped, except those
# written with always = $true (flags and the final "stopped" line). A write that fails is dropped: the log never
# stops SRRVRR.
function New-DailyLog {
    param(
        [AllowEmptyString()][string]$Folder, [Parameter(Mandatory)][string]$Prefix, [string]$Extension = 'log',
        [Parameter(Mandatory)][scriptblock]$Clock, [long]$CapBytes = 20MB
    )
    $log = [pscustomobject]@{ Folder = $Folder; Prefix = $Prefix; Extension = $Extension; Clock = $Clock; CapBytes = $CapBytes; Date = ''; Bytes = 0L; Capped = $false; Buffer = $null; Failed = $false }
    # With no folder yet (SRRVRR hasn't chosen its data folder), lines wait in memory; SetFolder writes them out.
    if (-not $Folder) { $log.Buffer = New-Object System.Collections.Generic.List[object] }
    $log | Add-Member ScriptMethod SetFolder {
        param([string]$NewFolder)
        $this.Folder = $NewFolder; $this.Date = ''
        $waiting = $this.Buffer; $this.Buffer = $null
        if ($waiting) { foreach ($w in $waiting) { $this.Write($w.Line, $w.Always) } }
    }
    $log | Add-Member ScriptMethod PathFor { param([DateTimeOffset]$Now) Join-Path $this.Folder ('{0}-{1}.{2}' -f $this.Prefix, $Now.ToString('yyyy-MM-dd'), $this.Extension) }
    $log | Add-Member ScriptMethod Write {
        param([string]$Line, [bool]$Always)
        if ($null -ne $this.Buffer) { $this.Buffer.Add(@{ Line = $Line; Always = $Always }); return }
        try {
            $now = & $this.Clock
            $path = $this.PathFor($now)
            $date = $now.ToString('yyyy-MM-dd')
            if ($date -ne $this.Date) {
                if (-not (Test-Path -LiteralPath $this.Folder)) { New-Item -ItemType Directory -Force -Path $this.Folder | Out-Null }
                $this.Date = $date
                $this.Bytes = if (Test-Path -LiteralPath $path) { (Get-Item -LiteralPath $path).Length } else { 0L }
                $this.Capped = $this.Bytes -ge $this.CapBytes
            }
            $utf8 = New-Object Text.UTF8Encoding($false)
            if (-not $Always -and $this.Bytes -ge $this.CapBytes) {
                if ($this.Capped) { return }
                $this.Capped = $true
                $Line = "daily size cap reached ($($this.CapBytes) bytes): only flags and the stopped line are written until tomorrow"
            }
            $bytes = $utf8.GetBytes($Line + "`r`n")
            [IO.File]::AppendAllText($path, $Line + "`r`n", $utf8)
            $this.Bytes += $bytes.Length
        } catch { $this.Failed = $true }   # the caller checks Failed to fall back to SRRVRR's own folder
    }
    $log
}

# Watches the background workers (runspaces). A worker that failed or ended means SRRVRR should stop with a crash
# code, so whatever started it starts it again. Workers: @(@{ Name; PowerShell }).
function Test-WorkerHealth {
    param([object[]]$Workers)
    foreach ($w in $Workers) {
        $info = $w.PowerShell.InvocationStateInfo
        if ($info.State -in 'Failed', 'Completed', 'Stopped') {
            $why = if ($info.State -eq 'Failed') { "$($w.Name) failed: $(if ($info.Reason) { $info.Reason.Message } else { 'no reason given' })" } else { "$($w.Name) ended" }
            $errors = @($w.PowerShell.Streams.Error | ForEach-Object { [string]$_ })
            return @{ Healthy = $false; Reason = $why; Errors = $errors; ExitCode = 1 }
        }
    }
    @{ Healthy = $true; Reason = $null; Errors = @(); ExitCode = $null }
}

Export-ModuleMember -Function Format-LogLine, Format-SrrException, New-ErrorThrottle, New-DailyLog, Test-WorkerHealth
