# The one Pester configuration, loaded by tools\Invoke-Checks.ps1 with New-PesterConfiguration -Hashtable.
@{
    Run          = @{
        Path     = 'tests'
        PassThru = $true
    }
    Filter       = @{
        ExcludeTag = @('Smoke', 'Elevated')
    }
    TestResult   = @{
        Enabled      = $true
        OutputFormat = 'NUnitXml'
        OutputPath   = 'out\test-results.xml'
    }
    CodeCoverage = @{
        Enabled               = $false
        Path                  = @('modules\*.psm1', 'tools\SRRVRR.Tools.psm1')
        OutputFormat          = 'JaCoCo'
        OutputPath            = 'out\coverage.xml'
        CoveragePercentTarget = 100
        UseBreakpoints        = $false
    }
    Output       = @{
        Verbosity = 'Normal'
    }
}
