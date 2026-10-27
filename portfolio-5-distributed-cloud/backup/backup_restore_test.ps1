<#
.SYNOPSIS
  Logical backup and restore test for the Copay database, with verification.

.DESCRIPTION
  1. Records row counts and a few checksums on the source database.
  2. pg_dump in custom format (compressed, restorable in parallel, selectable per table).
  3. Restores into a NEW database (copay_restore_test) with pg_restore.
  4. Compares counts and checksums, runs the ledger reconciliation on the restored copy.
  5. Drops the test database (use -Keep to keep it).
  A backup is only proven by a restore, so the script never stops at "dump created".

  Uses the standard PG* variables for the source (PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE).

.EXAMPLE
  .\backup_restore_test.ps1 | Tee-Object ..\evidence\p5-backup-restore.log
#>
param([switch]$Keep, [string]$BinDir = $(if ($env:PGBIN) { $env:PGBIN } else { 'C:\Program Files\PostgreSQL\18\bin' }))
$env:Path = "$BinDir;$env:Path"
$env:PGOPTIONS = '-c client_min_messages=warning'
$src  = if ($env:PGDATABASE) { $env:PGDATABASE } else { 'copay' }
$tgt  = 'copay_restore_test'
$out  = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $out | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$dump  = Join-Path $out "copay_$stamp.dump"

function Q([string]$db, [string]$sql) { (& psql -X -At -d $db -c $sql).Trim() }

$checks = @{
    users               = 'SELECT count(*) FROM users'
    wallets             = 'SELECT count(*) FROM wallets'
    loan_requests       = 'SELECT count(*) FROM loan_requests'
    loans               = 'SELECT count(*) FROM loans'
    repayments          = 'SELECT count(*) FROM repayments'
    ledger_entries      = 'SELECT count(*) FROM ledger_entries'
    ledger_amount_sum   = 'SELECT COALESCE(sum(amount),0) FROM ledger_entries'
    wallet_balance_sum  = 'SELECT COALESCE(sum(balance),0) FROM wallets'
    ledger_checksum     = "SELECT md5(string_agg(id::text || ':' || amount::text, ',' ORDER BY id)) FROM ledger_entries"
    reconciliation_bad  = 'SELECT count(*) FROM wallet_reconciliation WHERE difference <> 0'
}

Write-Host "Source database: $src on $($env:PGHOST):$($env:PGPORT)  ($(Q $src 'SELECT version()'))"

Write-Host "`n1. Taking the dump (custom format, compressed) ..."
$t = Measure-Command { & pg_dump -Fc -Z 6 -d $src -f $dump }
$size = (Get-Item $dump).Length
Write-Host ("   {0}  {1:N1} MB  in {2:N1} s" -f $dump, ($size / 1MB), $t.TotalSeconds)
Write-Host ("   Database size on disk: {0}" -f (Q $src "SELECT pg_size_pretty(pg_database_size('$src'))"))

Write-Host "`n   Contents of the dump (first entries of pg_restore --list):"
& pg_restore --list $dump | Select-Object -First 8 | ForEach-Object { "     $_" }
$schemaOnly = Join-Path $out "copay_schema_$stamp.sql"
& pg_dump --schema-only --no-owner -d $src -f $schemaOnly
Write-Host ("   Schema only SQL dump: {0} ({1:N0} KB), readable and diff friendly" -f $schemaOnly, ((Get-Item $schemaOnly).Length / 1KB))

Write-Host "`n2. Restoring into a new database '$tgt' ..."
& psql -X -q -d postgres -c "DROP DATABASE IF EXISTS $tgt" | Out-Null
# template0 is a pristine empty database (it already has the public schema the dump expects).
& psql -X -q -d postgres -c "CREATE DATABASE $tgt TEMPLATE template0" | Out-Null
$restoreOutput = $null
$t = Measure-Command { $restoreOutput = & pg_restore -d $tgt --no-owner -j 2 $dump 2>&1 }
$restoreErrors = @($restoreOutput | Where-Object { "$_" -match 'error' })
Write-Host ("   restore finished in {0:N1} s with {1} error(s)" -f $t.TotalSeconds, $restoreErrors.Count)
$restoreErrors | Select-Object -First 5 | ForEach-Object { "     $_" }

Write-Host "`n3. Comparing source and restored copy"
$allOk = $true
"{0,-20}{1,34}{2,34}  {3}" -f 'check', 'source', 'restored', 'result' | Write-Host
foreach ($k in $checks.Keys | Sort-Object) {
    $a = Q $src $checks[$k]; $b = Q $tgt $checks[$k]
    $ok = ($a -eq $b); if (-not $ok) { $allOk = $false }
    "{0,-20}{1,34}{2,34}  {3}" -f $k, $a, $b, $(if ($ok) { 'MATCH' } else { 'DIFFERENT' }) | Write-Host
}
Write-Host ("`nTriggers present on restored ledger_entries: {0} (source: {1})" -f
    (Q $tgt "SELECT count(*) FROM pg_trigger WHERE tgrelid = 'ledger_entries'::regclass AND NOT tgisinternal"),
    (Q $src "SELECT count(*) FROM pg_trigger WHERE tgrelid = 'ledger_entries'::regclass AND NOT tgisinternal"))

Write-Host "`n4. Does the restored database still enforce the rules? (append only ledger)"
$r = & psql -X -d $tgt -c 'DELETE FROM ledger_entries WHERE id = 1' 2>&1
Write-Host "   $($r | Select-Object -First 1)"

if (-not $Keep) { & psql -X -q -d postgres -c "DROP DATABASE $tgt" | Out-Null; Write-Host "`n5. Test database dropped." }
Write-Host ("`nOVERALL: {0}" -f $(if ($allOk) { 'backup verified by restore' } else { 'MISMATCH - investigate' }))
