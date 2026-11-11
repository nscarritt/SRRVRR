# The spec's budgets (docs/specs/2026-10-28-srrvrr-core-design.md, "Baseline and budgets") as data, for
# tools\Measure-SRRVRR.ps1. Baseline: the previous release (below).
@{
    ProcessCpuPercentOfMachineMax = 1
    MemoryVsPreviousReleaseMBMax  = 25
    StatsP95MsMax                 = 30
    HistoryMsMax                  = 50
    EventsMsMax                   = 50
    PageLoadMsMax                 = 150
    StartupSecondsMax             = 20
    DiskWriteMBPerDayMax          = 100
    TickMedianTolerancePercent    = 10
    TickMedianToleranceMs         = 5
    # Measured on PR 1 (#47); later PRs stay within the tolerance above.
    TickMsBaseline                = 44   # #47 test copy, 2026-10-29: median of 60 s
    # The previous release, for the next one's comparisons: v0.8.0, test copies on the server. Memory: the median of
    # 20 readings over a 10-minute soak beside v0.7.0, 2026-11-10 (269 MB; v0.7.0 275 MB). The rest: 150 s with
    # tools\Measure-SRRVRR.ps1, 2026-11-11, beside v0.9.0's test copy. Startup not re-measured (v0.7.0's).
    Baseline                      = @{
        Version         = 'v0.8.0'
        ProcessCpu      = 0.83
        PrivateMB       = 269
        StatsBytes      = 2333
        StatsP95Ms      = 9.2
        PageBytes       = 74217
        PageLoadMs      = 68
        StartupSeconds  = 15
    }
}
