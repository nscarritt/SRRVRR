# Fake performance-counter snapshots shaped like PerformanceCounterCategory.ReadCategory():
# category -> counter -> instance -> object with .Sample (a real CounterSample) and .RawValue.
# Samples use the NumberOfItems64 type, for which CounterSample.Calculate returns the new raw value, so a test's
# expected numbers are the values it put in.

function New-FakeSample([double]$Value, [long]$Time = 0) {
    $type = [Diagnostics.PerformanceCounterType]::NumberOfItems64
    $sample = New-Object Diagnostics.CounterSample ([long]$Value), 0, 0, 0, $Time, $Time, $type
    [pscustomobject]@{ Sample = $sample; RawValue = [long]$Value }
}

# $Data: @{ 'Category' = @{ 'Counter' = @{ 'instance' = value } } }
function New-FakeSnapshot([hashtable]$Data, [long]$Time = 1) {
    $snap = @{}
    foreach ($cat in $Data.Keys) {
        $snap[$cat] = @{}
        foreach ($counter in $Data[$cat].Keys) {
            $snap[$cat][$counter] = @{}
            foreach ($inst in $Data[$cat][$counter].Keys) { $snap[$cat][$counter][$inst] = New-FakeSample $Data[$cat][$counter][$inst] $Time }
        }
    }
    $snap
}

# A reader scriptblock that hands out the snapshots in order and throws on read number $ThrowOn (1-based).
function New-FakeCounterReader([object[]]$Snapshots, [int]$ThrowOn = 0) {
    $state = @{ Index = 0; Snapshots = $Snapshots; ThrowOn = $ThrowOn }
    { $state.Index++
      if ($state.Index -eq $state.ThrowOn) { throw 'fake counter read failed' }
      $state.Snapshots[[Math]::Min($state.Index, $state.Snapshots.Count) - 1] }.GetNewClosure()
}

# A stopwatch stand-in whose Elapsed is fixed.
function New-FakeStopwatch([double]$Milliseconds) {
    $sw = [pscustomobject]@{ Elapsed = [TimeSpan]::FromMilliseconds($Milliseconds) }
    $sw | Add-Member -MemberType ScriptMethod -Name Restart -Value { } -PassThru
}

Export-ModuleMember -Function New-FakeSample, New-FakeSnapshot, New-FakeCounterReader, New-FakeStopwatch
