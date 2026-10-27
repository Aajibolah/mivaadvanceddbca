<#
.SYNOPSIS
  Builds a PostgreSQL primary (port 5433) and a streaming replica (port 5434) on this machine.

.DESCRIPTION
  1. initdb a new primary with WAL settings for replication, start it.
  2. Create the replication role and the copay database.
  3. Optionally load the Copay data into the primary (-LoadData runs the Portfolio 1 seed against it).
  4. Take a base backup with pg_basebackup -R (writes standby.signal and primary_conninfo),
     using a replication slot so the primary keeps the WAL the replica still needs.
  5. Start the replica on port 5434.

  Needs $env:PGPASSWORD (used for every test instance). Re-run cleanup.ps1 first if .cluster\primary exists.

.EXAMPLE
  $env:PGPASSWORD = 'change_me'
  .\setup_replication.ps1 -LoadData
#>
param([switch]$LoadData)
. "$PSScriptRoot\..\common.ps1"

Write-Host '1. Creating and starting the primary (port 5433) ...'
New-Node -Name 'primary' -Port 5433 -Conf @(
    'synchronous_commit = on',
    'wal_keep_size = 256MB',
    'log_min_messages = warning')
Start-Node -Name 'primary' -Port 5433

Write-Host '2. Creating replication role and database ...'
$pw = $env:PGPASSWORD.Replace("'", "''")
Invoke-Sql -Port 5433 -Db postgres -Sql "CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '$pw'" | Out-Null
Invoke-Sql -Port 5433 -Db postgres -Sql 'CREATE DATABASE copay' | Out-Null

if ($LoadData) {
    Write-Host '3. Loading Copay data into the primary (about 3 minutes) ...'
    # Point the seed at the primary, then put the caller's environment back.
    $saved = @{}
    foreach ($v in 'PGHOST', 'PGPORT', 'PGDATABASE', 'PGUSER') { $saved[$v] = [Environment]::GetEnvironmentVariable($v) }
    try {
        $env:PGHOST = 'localhost'; $env:PGPORT = '5433'; $env:PGDATABASE = 'copay'; $env:PGUSER = $DbUser
        & $Python (Join-Path $Repo 'portfolio-1-database-design\seed\generate_seed.py') --reset
        if ($LASTEXITCODE -ne 0) { throw 'seed failed' }
    } finally {
        foreach ($v in $saved.Keys) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) }
    }
} else {
    Write-Host '3. Skipping data load (use -LoadData to load the full Copay data first).'
}

Write-Host '4. Base backup of the primary into the replica directory ...'
$replicaDir = Get-NodeDir 'replica1'
$conn = "host=localhost port=5433 user=replicator password=$($env:PGPASSWORD) application_name=replica1"
& pg_basebackup --dbname="$conn" -D $replicaDir -X stream -R -C -S replica1_slot
if ($LASTEXITCODE -ne 0) { throw 'pg_basebackup failed' }
# The copied postgresql.conf says port 5433; a later line wins, so override it.
Add-Content -Path (Join-Path $replicaDir 'postgresql.conf') -Value @('port = 5434', 'hot_standby = on')

Write-Host '5. Starting the replica (port 5434) ...'
Start-Node -Name 'replica1' -Port 5434

Start-Sleep -Seconds 2
Write-Host "`nPrimary view of replication:"
Show-Sql -Port 5433 -Db postgres -Sql "SELECT application_name, state, sync_state, sent_lsn, replay_lsn FROM pg_stat_replication"
Write-Host 'Replica is in recovery (read only):'
Show-Sql -Port 5434 -Db postgres -Sql 'SELECT pg_is_in_recovery() AS in_recovery'
