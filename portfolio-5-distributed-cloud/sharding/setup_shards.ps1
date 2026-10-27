<#
.SYNOPSIS
  Creates three PostgreSQL instances: shard1 (5441), shard2 (5442) and a router (5440) that
  connects to both through postgres_fdw and exposes hash-partitioned tables.

.DESCRIPTION
  Why postgres_fdw and not Citus: Citus is a PostgreSQL extension that needs its own build or
  package and has no Windows installer, so it cannot be used without containers or Linux.
  postgres_fdw ships with PostgreSQL and is enough to show the ideas the course asks for:
  a shard key, routing, pruning, fan-out queries and the cross shard transaction problem.
  The cost of that choice is explained in sharding-design.md (no parallel fan-out, no
  distributed transactions, no rebalancing tool).

  Needs $env:PGPASSWORD. Use cleanup.ps1 to remove the instances.
#>
param([string]$SourcePort = '5432', [int]$LedgerLimit = 60000, [switch]$SkipLoad)
. "$PSScriptRoot\..\common.ps1"

Write-Host 'Creating shard1, shard2 and router ...'
foreach ($n in @(@('shard1', 5441), @('shard2', 5442), @('router', 5440))) {
    New-Node -Name $n[0] -Port $n[1] -Conf @('max_prepared_transactions = 20')   # needed for PREPARE TRANSACTION (2PC)
    Start-Node -Name $n[0] -Port $n[1]
    Invoke-Sql -Port $n[1] -Db postgres -Sql "CREATE DATABASE $(if ($n[0] -eq 'router') { 'copay_router' } else { 'copay_shard' })" | Out-Null
}

Write-Host 'Creating shard tables ...'
foreach ($p in 5441, 5442) { Invoke-SqlFile -Port $p -Db copay_shard -File (Join-Path $PSScriptRoot 'shard_init.sql') }

Write-Host 'Creating the router and its foreign partitions ...'
$pw = "'" + $env:PGPASSWORD.Replace("'", "''") + "'"
Invoke-SqlFile -Port 5440 -Db copay_router -File (Join-Path $PSScriptRoot 'router_init.sql') -Extra @('-v', "pw=$pw")

if (-not $SkipLoad) {
    Write-Host "Loading wallets and up to $LedgerLimit ledger rows from the Copay database on port $SourcePort ..."
    & $Python (Join-Path $PSScriptRoot 'shard_loader.py') --source-port $SourcePort --router-port 5440 --ledger-limit $LedgerLimit
    if ($LASTEXITCODE -ne 0) { throw 'shard_loader.py failed' }
}
Write-Host "`nReady. Router: psql -h localhost -p 5440 -U $DbUser -d copay_router"
