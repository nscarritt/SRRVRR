# The Workstation role's budgets (docs/specs/2026-11-26-srrvrr-workstation-design.md, section 13) as data, for
# tools\Measure-SRRVRR.ps1 -Budgets tools\budgets.workstation.psd1. Same limits as budgets.psd1; the baseline is a
# Workstation test copy on the dev PC, which has more CPUs and GPU counters than the server, so it isn't comparable
# with the Server's baseline.
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
    # Measured on #90's Workstation test copy, 2026-11-27: median of 60 s, unelevated, no ComfyUi.
    TickMsBaseline                = 11
    Baseline                      = @{
        Version         = 'v0.10.0 #90'
        ProcessCpu      = 0.21
        PrivateMB       = 239
        StatsBytes      = 2559
        StatsP95Ms      = 5.8
        PageBytes       = 75494
        PageLoadMs      = 40.1
        StartupSeconds  = 4.9
    }
}
