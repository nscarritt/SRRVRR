# The spec's budgets (docs/specs/2026-10-28-srrvrr-core-design.md, "Baseline and budgets") as data, for
# tools\Measure-SRRVRR.ps1. Baseline: v0.6.0 on the live server, 2026-10-28.
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
    Baseline                      = @{
        Version         = 'v0.6.0'
        ProcessCpu      = 0.5
        PrivateMB       = 300
        StatsBytes      = 1920
        StatsP95Ms      = 25
        PageBytes       = 66574
        PageLoadMs      = 75
        StartupSeconds  = 17
    }
}
