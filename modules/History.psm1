# 15 minutes of graph history kept on the server (spec section 2): one reading a second per line, in rings of
# doubles under one lock, written to JSON by hand and saved to state\history.json.
Set-StrictMode -Version 2

if (-not ('SrrHistoryStore' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

public class SrrHistoryCopy {
    public long NewestMs;
    public int StepMs;
    public System.Collections.Specialized.OrderedDictionary Lines = new System.Collections.Specialized.OrderedDictionary();
}

public class SrrHistoryStore {
    private readonly object gate = new object();
    private readonly List<string> names = new List<string>();
    private readonly Dictionary<string, double[]> rings = new Dictionary<string, double[]>();
    private int head = -1;            // the slot holding the newest second; -1 until the first reading
    private long newestStep;          // the newest second, as a count of steps since 1970
    public readonly int Slots;
    public readonly int StepMs;

    public SrrHistoryStore(int slots, int stepMs) { Slots = slots; StepMs = stepMs; }

    public string[] Names { get { lock (gate) { return names.ToArray(); } } }

    public void Register(string name) {
        lock (gate) {
            if (rings.ContainsKey(name)) return;
            double[] ring = new double[Slots];
            for (int i = 0; i < Slots; i++) ring[i] = double.NaN;
            rings[name] = ring;
            names.Add(name);
        }
    }

    // Numbers only: anything else (and infinity) is stored as missing.
    public static double ToReading(object value) {
        if (value == null) return double.NaN;
        if (value is System.Management.Automation.PSObject) value = ((System.Management.Automation.PSObject)value).BaseObject;
        double d;
        if (value is double) d = (double)value;
        else if (value is float || value is int || value is long || value is short || value is byte || value is decimal ||
                 value is uint || value is ulong || value is ushort || value is sbyte) d = Convert.ToDouble(value, CultureInfo.InvariantCulture);
        else return double.NaN;
        return (double.IsInfinity(d) ? double.NaN : d);
    }

    // Moves the newest second forward to the step for timeMs, marking skipped seconds missing. Caller holds the lock.
    private void AdvanceTo(long step) {
        if (head < 0) { head = 0; newestStep = step; return; }
        if (step <= newestStep) return;
        long gap = step - newestStep;
        int clear = (int)Math.Min(gap, (long)Slots);
        for (int i = 1; i <= clear; i++) {
            int slot = (int)((head + i) % Slots);
            foreach (double[] ring in rings.Values) ring[slot] = double.NaN;
        }
        head = (int)((head + gap) % Slots);
        newestStep = step;
    }

    public void Append(string name, object value, long timeMs) {
        double reading = ToReading(value);
        lock (gate) {
            double[] ring;
            if (!rings.TryGetValue(name, out ring)) throw new ArgumentException("History line '" + name + "' is not registered.");
            long step = timeMs / StepMs;
            AdvanceTo(step);
            long back = newestStep - step;
            if (back >= Slots) return;   // older than the ring holds (the clock stepped back)
            ring[(int)(((head - back) % Slots + Slots) % Slots)] = reading;
        }
    }

    // Marks every second up to timeMs missing (used after loading a saved file).
    public void Advance(long timeMs) { lock (gate) { if (head >= 0) AdvanceTo(timeMs / StepMs); } }

    // Puts saved values (oldest first, the last one at newestMs) into an empty store.
    public void Load(long newestMs, Dictionary<string, double[]> lines) {
        lock (gate) {
            head = Slots - 1; newestStep = newestMs / StepMs;
            foreach (string n in names) {
                double[] ring = rings[n];
                for (int i = 0; i < Slots; i++) ring[i] = double.NaN;
                double[] saved;
                if (!lines.TryGetValue(n, out saved)) continue;
                int take = Math.Min(saved.Length, Slots);
                Array.Copy(saved, saved.Length - take, ring, Slots - take, take);
            }
        }
    }

    public SrrHistoryCopy Copy() {
        lock (gate) {
            SrrHistoryCopy c = new SrrHistoryCopy();
            c.StepMs = StepMs;
            c.NewestMs = head < 0 ? 0 : newestStep * StepMs;
            foreach (string n in names) {
                double[] ring = rings[n], o = new double[Slots];
                for (int i = 0; i < Slots; i++) o[i] = head < 0 ? double.NaN : ring[(head + 1 + i) % Slots];
                c.Lines[n] = o;
            }
            return c;
        }
    }

    public static string ToJson(SrrHistoryCopy c) {
        StringBuilder sb = new StringBuilder(64 * 1024);
        sb.Append("{\"version\":1,\"newestMs\":").Append(c.NewestMs.ToString(CultureInfo.InvariantCulture));
        sb.Append(",\"stepMs\":").Append(c.StepMs.ToString(CultureInfo.InvariantCulture)).Append(",\"lines\":{");
        bool firstLine = true;
        foreach (System.Collections.DictionaryEntry e in c.Lines) {
            if (!firstLine) sb.Append(',');
            firstLine = false;
            sb.Append('"').Append(((string)e.Key).Replace("\\", "\\\\").Replace("\"", "\\\"")).Append("\":[");
            double[] v = (double[])e.Value;
            for (int i = 0; i < v.Length; i++) {
                if (i > 0) sb.Append(',');
                if (double.IsNaN(v[i]) || double.IsInfinity(v[i])) { sb.Append("null"); continue; }
                double r = Math.Round(v[i], 3, MidpointRounding.AwayFromZero);
                if (r == 0) r = 0;   // no "-0"
                sb.Append(r.ToString("R", CultureInfo.InvariantCulture));
            }
            sb.Append(']');
        }
        return sb.Append("}}").ToString();
    }
}
'@
}

function New-HistoryStore {
    param([int]$Slots = 900, [int]$StepMs = 1000, [string[]]$Lines = @('cpu', 'mem', 'gpu', 'rx', 'tx'))
    $s = New-Object SrrHistoryStore($Slots, $StepMs)
    foreach ($n in $Lines) { $s.Register($n) }
    , $s
}

function ConvertTo-HistoryJson([SrrHistoryCopy]$Copy) { [SrrHistoryStore]::ToJson($Copy) }

# Writes history.json.tmp, then swaps it in. Returns @{ Ok; Error } and never throws.
function Save-History {
    param([SrrHistoryStore]$Store, [string]$StatePath)
    $tmp = $null
    try {
        # [IO.Path]::Combine, not Join-Path: Join-Path fails on a drive that's gone (an unplugged USB data drive).
        $target = [IO.Path]::Combine($StatePath, 'history.json')
        $tmp = "$target.tmp"
        [IO.File]::WriteAllText($tmp, (ConvertTo-HistoryJson $Store.Copy()), (New-Object Text.UTF8Encoding($false)))
        # [NullString]::Value: a plain $null would arrive as an empty backup path.
        if ([IO.File]::Exists($target)) { [IO.File]::Replace($tmp, $target, [NullString]::Value) } else { [IO.File]::Move($tmp, $target) }
        @{ Ok = $true; Error = $null }
    } catch {
        try { if ($tmp -and [IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } } catch { }
        @{ Ok = $false; Error = "couldn't save the history: $($_.Exception.Message)" }
    }
}

function Move-HistoryAside([string]$Path) {
    $bad = "$Path.bad"
    if ([IO.File]::Exists($bad)) { [IO.File]::Delete($bad) }
    [IO.File]::Move($Path, $bad)
}

# Loads state\history.json into an empty store. Returns @{ Loaded; Reason }. Damaged, oversized or unknown-version
# files are renamed history.json.bad; stale or future ones are left as they are.
function Import-History {
    param([string]$StatePath, [SrrHistoryStore]$Store, [DateTimeOffset]$Now, [long]$MaxBytes = 2MB, [TimeSpan]$MaxAge = [TimeSpan]::FromMinutes(15))
    $path = Join-Path $StatePath 'history.json'
    if (-not [IO.File]::Exists($path)) { return @{ Loaded = $false; Reason = 'none' } }
    try {
        if ((New-Object IO.FileInfo $path).Length -gt $MaxBytes) { Move-HistoryAside $path; return @{ Loaded = $false; Reason = "too big (over $MaxBytes bytes)" } }
        $doc = $null
        try { $doc = [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { }
        $valid = $doc -and ($doc.PSObject.Properties.Name -contains 'version')
        if ($valid -and $doc.version -ne 1) { Move-HistoryAside $path; return @{ Loaded = $false; Reason = "unknown version $($doc.version)" } }
        $lines = New-Object 'System.Collections.Generic.Dictionary[string,double[]]'
        if ($valid) {
            $valid = ($doc.newestMs -is [long] -or $doc.newestMs -is [int]) -and $doc.stepMs -eq $Store.StepMs -and $doc.lines -is [PSCustomObject]
        }
        if ($valid) {
            foreach ($p in $doc.lines.PSObject.Properties) {
                if ($p.Value -isnot [object[]]) { $valid = $false; break }
                $lines[$p.Name] = [double[]]@($p.Value | ForEach-Object { [SrrHistoryStore]::ToReading($_) })
            }
        }
        if (-not $valid) { Move-HistoryAside $path; return @{ Loaded = $false; Reason = 'damaged' } }
        $nowMs = $Now.ToUnixTimeMilliseconds()
        if ($doc.newestMs -gt $nowMs) { return @{ Loaded = $false; Reason = 'future' } }
        if ($nowMs - $doc.newestMs -gt $MaxAge.TotalMilliseconds) { return @{ Loaded = $false; Reason = 'stale' } }
        $Store.Load([long]$doc.newestMs, $lines)
        $Store.Advance($nowMs)
        @{ Loaded = $true; Reason = $null }
    } catch {
        @{ Loaded = $false; Reason = "couldn't read the history: $($_.Exception.Message)" }
    }
}

function Test-HistorySaveDue {
    param([DateTimeOffset]$LastSave, [DateTimeOffset]$Now, [TimeSpan]$Interval = [TimeSpan]::FromMinutes(5))
    ($Now - $LastSave) -ge $Interval
}

Export-ModuleMember -Function New-HistoryStore, ConvertTo-HistoryJson, Save-History, Import-History, Test-HistorySaveDue
