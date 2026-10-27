<#
.SYNOPSIS
  Measures the cost of synchronous replication and shows what it does to availability.

.DESCRIPTION
  Part A  asynchronous: commits do not wait for the replica.
  Part B  synchronous_standby_names = 'replica1': commits wait for the replica
          (remote_write, on = flushed, remote_apply = visible to reads there).
  Part C  the replica goes down while synchronous replication is required: commits HANG.
          This is the consistency over availability choice made visible. They are released by
          switching back to asynchronous replication (what an operator or an HA tool would do).

  Each timing is 300 single row commits on the primary; absolute numbers depend on your disk, so
  compare the modes with each other, not with anyone else's machine.
  Requires both nodes from setup_replication.ps1 to be running.
#>
. "$PSScriptRoot\..\common.ps1"

# COMMIT inside a DO block only works when the DO is the only statement of the call,
# so the table is created separately.
Invoke-Sql -Port 5433 -Db copay -Sql 'CREATE TABLE IF NOT EXISTS sync_test(id serial PRIMARY KEY, v int)' | Out-Null
Invoke-Sql -Port 5433 -Db postgres -Sql "ALTER SYSTEM SET synchronous_standby_names = ''" | Out-Null
Invoke-Sql -Port 5433 -Db postgres -Sql 'SELECT pg_reload_conf()' | Out-Null
Start-Sleep -Seconds 1

$timing = @'
DO $$
DECLARE t0 timestamptz := clock_timestamp(); i int;
BEGIN
  FOR i IN 1..300 LOOP INSERT INTO sync_test(v) VALUES (i); COMMIT; END LOOP;
  RAISE NOTICE '%', format('synchronous_commit=%-12s standby_names=%-10s 300 commits: %s ms',
        current_setting('synchronous_commit'), COALESCE(NULLIF(current_setting('synchronous_standby_names'), ''), '(none)'),
        round(extract(epoch FROM clock_timestamp() - t0) * 1000));
END $$;
'@

function Measure-Mode([string]$Mode) {
    $env:PGOPTIONS = "-c synchronous_commit=$Mode -c client_min_messages=notice"
    $out = & psql -X -q -h localhost -p 5433 -U $DbUser -d copay -c $timing 2>&1
    $out | ForEach-Object { $_.ToString() -replace '^.*NOTICE:\s+', '' } | Where-Object { $_ -match 'commits' }
    $env:PGOPTIONS = '-c client_min_messages=warning'
}

Write-Host '== Part A: asynchronous replication (no synchronous standby configured)'
Invoke-Sql -Port 5433 -Db postgres -Sql "ALTER SYSTEM SET synchronous_standby_names = ''" | Out-Null
Invoke-Sql -Port 5433 -Db postgres -Sql 'SELECT pg_reload_conf()' | Out-Null
Start-Sleep -Seconds 1
foreach ($m in 'off', 'local', 'on') { Measure-Mode $m }

Write-Host "`n== Part B: synchronous replication to replica1"
Invoke-Sql -Port 5433 -Db postgres -Sql "ALTER SYSTEM SET synchronous_standby_names = 'replica1'" | Out-Null
Invoke-Sql -Port 5433 -Db postgres -Sql 'SELECT pg_reload_conf()' | Out-Null
Start-Sleep -Seconds 1
Show-Sql -Port 5433 -Db postgres -Sql 'SELECT application_name, sync_state FROM pg_stat_replication'
foreach ($m in 'local', 'remote_write', 'on', 'remote_apply') { Measure-Mode $m }

Write-Host "`n== Part C: replica disappears while synchronous replication is required"
Stop-Node -Name 'replica1'
$p = Start-Process -FilePath (Join-Path $PgBin 'psql.exe') -PassThru -WindowStyle Hidden `
     -ArgumentList @('-X', '-q', '-h', 'localhost', '-p', '5433', '-U', $DbUser, '-d', 'copay', '-c', '"INSERT INTO sync_test(v) VALUES (-1)"')   # Start-Process does not quote for us
$finished = $p.WaitForExit(6000)
if (-not $finished) {
    Write-Host '  After 6 seconds the INSERT is still waiting: the primary cannot confirm the commit without the replica.'
    Show-Sql -Port 5433 -Db postgres -Sql "SELECT pid, wait_event_type, wait_event, left(query, 40) AS query FROM pg_stat_activity WHERE wait_event = 'SyncRep'"
} else {
    Write-Host '  UNEXPECTED: the commit completed without the replica.'
}
Write-Host '  Operator action: fall back to asynchronous replication (accept the risk of losing the newest commits).'
Invoke-Sql -Port 5433 -Db postgres -Sql "ALTER SYSTEM SET synchronous_standby_names = ''" | Out-Null
Invoke-Sql -Port 5433 -Db postgres -Sql 'SELECT pg_reload_conf()' | Out-Null
$p.WaitForExit(10000) | Out-Null
Write-Host "  Blocked commit released: finished = $($p.HasExited)"

Write-Host "`nRestoring: starting the replica again"
Start-Node -Name 'replica1' -Port 5434
Invoke-Sql -Port 5433 -Db postgres -Sql 'ALTER SYSTEM RESET synchronous_standby_names' | Out-Null
Invoke-Sql -Port 5433 -Db postgres -Sql 'SELECT pg_reload_conf()' | Out-Null
