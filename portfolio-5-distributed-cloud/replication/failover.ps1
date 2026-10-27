<#
.SYNOPSIS
  Simulates losing the primary and promoting the replica (manual failover).

.DESCRIPTION
  1. Writes a marker row on the primary and confirms the replica has it.
  2. Stops the primary abruptly-ish (fast shutdown) to simulate an outage.
  3. Shows the replica is still read only.
  4. Promotes the replica with pg_promote() and proves it now accepts writes.

  What a real application would do is described in the README. The old primary must NOT be
  restarted as a primary afterwards (split brain): it has to be rebuilt as a replica of the
  new primary (pg_rewind or a fresh pg_basebackup).
#>
. "$PSScriptRoot\..\common.ps1"

Write-Host '1. Marker row on the primary, replicated to the replica'
Invoke-Sql -Port 5433 -Db copay -Sql "CREATE TABLE IF NOT EXISTS failover_marker(id serial PRIMARY KEY, note text, at timestamptz DEFAULT now())" | Out-Null
Invoke-Sql -Port 5433 -Db copay -Sql "INSERT INTO failover_marker(note) VALUES ('written on the old primary')" | Out-Null
Start-Sleep -Seconds 1
Show-Sql -Port 5434 -Db copay -Sql 'SELECT * FROM failover_marker'

Write-Host "`n2. Primary goes down"
Stop-Node -Name 'primary'

Write-Host "`n3. Replica before promotion (still read only):"
Show-Sql -Port 5434 -Db copay -Sql 'SELECT pg_is_in_recovery() AS in_recovery'
Show-Sql -Port 5434 -Db copay -Sql "INSERT INTO failover_marker(note) VALUES ('should fail')"

Write-Host "`n4. Promoting the replica with pg_promote()"
Show-Sql -Port 5434 -Db postgres -Sql 'SELECT pg_promote(wait => true)'
Show-Sql -Port 5434 -Db postgres -Sql 'SELECT pg_is_in_recovery() AS in_recovery'
Show-Sql -Port 5434 -Db copay -Sql "INSERT INTO failover_marker(note) VALUES ('written on the NEW primary') RETURNING *"
Show-Sql -Port 5434 -Db copay -Sql 'SELECT * FROM failover_marker ORDER BY id'
Invoke-Sql -Port 5434 -Db postgres -Sql 'CHECKPOINT' | Out-Null
Show-Sql -Port 5434 -Db postgres -Sql 'SELECT timeline_id FROM pg_control_checkpoint()'
Write-Host "`nNote the timeline id: promotion starts a new timeline, which is how PostgreSQL stops a stale old primary from silently rejoining."
