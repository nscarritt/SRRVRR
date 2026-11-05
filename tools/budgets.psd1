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
    # The previous release, for the next one's comparisons: v0.7.0's 60-minute soak (T50-56), a test copy on the
    # server, 2026-11-04, beside v0.6.0 (269 MB private after 60 minutes, so v0.7.0 is 9 MB more).
    Baseline                      = @{
        Version         = 'v0.7.0'
        ProcessCpu      = 0.68
        PrivateMB       = 278
        StatsBytes      = 2212
        StatsP95Ms      = 8.6
        PageBytes       = 72587
        PageLoadMs      = 80
        StartupSeconds  = 15
    }
}
