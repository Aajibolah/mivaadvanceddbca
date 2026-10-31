<#
.SYNOPSIS
  Captures EXPLAIN (ANALYZE, BUFFERS) output for every query in queries\.

.DESCRIPTION
  -Phase before : drops the performance indexes, ANALYZEs, saves plans\before_<query>.txt
  -Phase after  : creates the indexes (indexes.sql), saves plans\after_<query>.txt
  Each query is run once to warm the cache and once more for the saved plan, so
  the saved timing is a warm cache timing. Re-run on your own machine: the numbers
  in the report must be yours.

  Connection comes from the standard PG* variables (PGHOST, PGPORT, PGUSER,
  PGPASSWORD, PGDATABASE). psql must be on the PATH.

.EXAMPLE
  .\run_plans.ps1 -Phase before
  .\run_plans.ps1 -Phase after
  python summarise_plans.py
#>
param(
    [Parameter(Mandatory = $true)][ValidateSet('before', 'after')][string]$Phase
)
# Windows PowerShell 5.1 turns any psql stderr text (even NOTICEs) into an error with
# 'Stop', so errors are detected through psql's exit code instead.
$ErrorActionPreference = 'Continue'
$env:PGOPTIONS = '-c client_min_messages=warning'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$plans = Join-Path $here 'plans'
New-Item -ItemType Directory -Force $plans | Out-Null

function Invoke-Psql([string[]]$PsqlArgs) {
    & psql -X -q -v ON_ERROR_STOP=1 @PsqlArgs
    if ($LASTEXITCODE -ne 0) { throw "psql failed: $PsqlArgs" }
}

if ($Phase -eq 'before') {
    Write-Host 'Dropping performance indexes (baseline) ...'
    Invoke-Psql @('-f', (Join-Path $here 'indexes_drop.sql'))
} else {
    Write-Host 'Creating indexes and refreshing statistics ...'
    Invoke-Psql @('-f', (Join-Path $here 'indexes.sql'))
}

# Parameters: a busy wallet and a busy lender, so the queries return real work.
$walletId = (& psql -X -At -c "SELECT wallet_id FROM (SELECT wallet_id, count(*) c FROM ledger_entries GROUP BY 1 ORDER BY c DESC LIMIT 1 OFFSET 5) x").Trim()
$lenderId = (& psql -X -At -c "SELECT lender_id FROM (SELECT lender_id, count(*) c FROM loan_fundings GROUP BY 1 ORDER BY c DESC LIMIT 1 OFFSET 3) x").Trim()
$version  = (& psql -X -At -c "SHOW server_version").Trim()
$vars = @('-v', "wallet_id=$walletId", '-v', "lender_id=$lenderId",
          '-v', 'as_of=2026-10-15', '-v', 'as_of_ts=2026-10-15 23:00:00+00')
Write-Host "Parameters: wallet_id=$walletId lender_id=$lenderId  (PostgreSQL $version)"

# Windows PowerShell 5.1 adds a byte order mark (BOM) when it writes 'utf8'. A psql client running
# with a Windows code page reads those three bytes as text and fails ("ï»¿EXPLAIN"). Write the files
# without a BOM instead.
$noBom = New-Object System.Text.UTF8Encoding($false)
$tmp = Join-Path $env:TEMP 'copay_explain.sql'
foreach ($file in Get-ChildItem (Join-Path $here 'queries') -Filter 'q*.sql' | Sort-Object Name) {
    $name = $file.BaseName
    $body = [System.IO.File]::ReadAllText($file.FullName)
    [System.IO.File]::WriteAllText($tmp, "EXPLAIN (ANALYZE, BUFFERS, SETTINGS)`n" + $body, $noBom)
    Invoke-Psql (@('-o', 'NUL', '-f', $tmp) + $vars)                  # warm up
    $out = Join-Path $plans "${Phase}_${name}.txt"
    $header = "-- $name | phase=$Phase | PostgreSQL $version | wallet_id=$walletId lender_id=$lenderId | $(Get-Date -Format s)`n"
    Invoke-Psql (@('-o', "$out.tmp", '-f', $tmp) + $vars)
    [System.IO.File]::WriteAllText($out, $header + "`n" + ((Get-Content "$out.tmp") -join "`n") + "`n", $noBom)
    Remove-Item "$out.tmp"
    Write-Host "  saved $out"
}
Remove-Item $tmp -ErrorAction SilentlyContinue
Write-Host 'Done. Next: python summarise_plans.py'
