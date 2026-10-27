<#
.SYNOPSIS
  Shows asynchronous replication lag and the stale read it causes.

.DESCRIPTION
  The replica is told to delay applying WAL by 5 seconds (recovery_min_apply_delay) so the
  effect is visible on a fast local machine. A row is written on the primary and read from the
  replica straight away (not there yet), then again after the delay (there).
  This is the "read your own write" problem: after a user funds their wallet, a balance read from
  a lagging replica would show the old value.
  Requires setup_replication.ps1 to have been run and both nodes running.
#>
. "$PSScriptRoot\..\common.ps1"

Invoke-Sql -Port 5433 -Db copay -Sql 'CREATE TABLE IF NOT EXISTS lag_test(id serial PRIMARY KEY, note text, written_at timestamptz DEFAULT now())' | Out-Null
Start-Sleep -Seconds 1
Write-Host '1. Make the replica apply changes 5 seconds late (simulated slow network or heavy replay)'
Invoke-Sql -Port 5434 -Db postgres -Sql "ALTER SYSTEM SET recovery_min_apply_delay = '5s'" | Out-Null
Invoke-Sql -Port 5434 -Db postgres -Sql 'SELECT pg_reload_conf()' | Out-Null

Write-Host "`n2. Write on the primary"
Show-Sql -Port 5433 -Db copay -Sql "INSERT INTO lag_test(note) VALUES ('balance updated') RETURNING id, note"

Write-Host "`n3. Read from the replica immediately: the row is NOT visible (stale read)"
Show-Sql -Port 5434 -Db copay -Sql "SELECT count(*) AS rows_visible_on_replica FROM lag_test WHERE note = 'balance updated'"
Show-Sql -Port 5433 -Db postgres -Sql "SELECT application_name, sync_state, pg_wal_lsn_diff(sent_lsn, replay_lsn) AS bytes_behind, replay_lag FROM pg_stat_replication"

Write-Host "`n4. Wait 7 seconds and read again"
Start-Sleep -Seconds 7
Show-Sql -Port 5434 -Db copay -Sql "SELECT count(*) AS rows_visible_on_replica FROM lag_test WHERE note = 'balance updated'"

Write-Host "`n5. Remove the artificial delay"
Invoke-Sql -Port 5434 -Db postgres -Sql 'ALTER SYSTEM RESET recovery_min_apply_delay' | Out-Null
Invoke-Sql -Port 5434 -Db postgres -Sql 'SELECT pg_reload_conf()' | Out-Null
Write-Host 'Done. Design consequence: reads that must see the user''s own latest write (balance after a transfer) go to the primary; dashboards, history and search may use the replica.'
