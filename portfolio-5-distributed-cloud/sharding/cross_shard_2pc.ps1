<#
.SYNOPSIS
  Demonstrates a money transfer between two wallets that live on DIFFERENT shards,
  using two phase commit (PREPARE TRANSACTION / COMMIT PREPARED), and what happens when one side fails.

.DESCRIPTION
  postgres_fdw cannot make two servers commit atomically, so the "coordinator" (this script) does it:
    Phase 1  prepare the debit on shard A and the credit on shard B. Both are now durable but invisible and
             hold their row locks.
    Phase 2  if BOTH prepared, COMMIT PREPARED on both. If either failed, ROLLBACK PREPARED on the other.
  Scenario 1 succeeds. Scenario 2 fails on shard B (the destination wallet is frozen), so the
  prepared debit on shard A is rolled back and no money is lost or created.
  Scenario 3 shows the danger: a prepared transaction left behind blocks its rows until someone resolves it.

  Real systems use a transaction manager that records the decision durably, or avoid 2PC with a saga (see
  sharding-design.md). Requires setup_shards.ps1 to have been run.
#>
. "$PSScriptRoot\..\common.ps1"

function Scalar([int]$Port, [string]$Sql) { (& psql -X -At -h localhost -p $Port -U $DbUser -d copay_shard -c $Sql).Trim() }
function Run([int]$Port, [string]$Sql) { & psql -X -q -h localhost -p $Port -U $DbUser -d copay_shard -v ON_ERROR_STOP=1 -c $Sql 2>&1 }

# One rich wallet on each shard.
$a = (Scalar 5441 "SELECT id FROM wallets_s WHERE balance >= 1000 ORDER BY id LIMIT 1")
$b = (Scalar 5442 "SELECT id FROM wallets_s WHERE balance >= 0 ORDER BY id LIMIT 1")
if (-not $a -or -not $b) { throw 'No suitable wallets found. Did setup_shards.ps1 load the data?' }
function Balances { "  shard1 wallet $a = $(Scalar 5441 "SELECT balance FROM wallets_s WHERE id = $a")   |   shard2 wallet $b = $(Scalar 5442 "SELECT balance FROM wallets_s WHERE id = $b")" }

Write-Host "Transferring NGN 100 from wallet $a (shard1) to wallet $b (shard2)"
Write-Host 'Before:'; Balances

Write-Host "`n=== Scenario 1: both sides succeed ==="
Run 5441 "BEGIN; UPDATE wallets_s SET balance = balance - 100 WHERE id = $a; PREPARE TRANSACTION 'xfer-1-shard1';" | Out-Null
Run 5442 "BEGIN; UPDATE wallets_s SET balance = balance + 100 WHERE id = $b; PREPARE TRANSACTION 'xfer-1-shard2';" | Out-Null
Write-Host 'Phase 1 done. Both prepared (durable, not yet visible):'
Balances
Write-Host "  prepared on shard1: $(Scalar 5441 'SELECT count(*) FROM pg_prepared_xacts')   prepared on shard2: $(Scalar 5442 'SELECT count(*) FROM pg_prepared_xacts')"
Write-Host '  A concurrent update of the locked row on shard1 must wait (lock_timeout 2s):'
Run 5441 "SET lock_timeout = '2s'; UPDATE wallets_s SET balance = balance WHERE id = $a;" | ForEach-Object { "    $_" }
Run 5441 "COMMIT PREPARED 'xfer-1-shard1'" | Out-Null
Run 5442 "COMMIT PREPARED 'xfer-1-shard2'" | Out-Null
Write-Host 'Phase 2 done (committed on both):'; Balances

Write-Host "`n=== Scenario 2: the credit side fails, so the debit must be rolled back ==="
Run 5441 "BEGIN; UPDATE wallets_s SET balance = balance - 100 WHERE id = $a; PREPARE TRANSACTION 'xfer-2-shard1';" | Out-Null
$check = Run 5442 'BEGIN; DO $$ BEGIN RAISE EXCEPTION ''destination wallet is frozen''; END $$; PREPARE TRANSACTION ''xfer-2-shard2'';'
Write-Host "  shard2 refused: $($check | Select-Object -First 1)"
Run 5442 "ROLLBACK" | Out-Null
Write-Host '  Coordinator decision: abort. Rolling back the prepared debit on shard1.'
Run 5441 "ROLLBACK PREPARED 'xfer-2-shard1'" | Out-Null
Write-Host '  After (unchanged by scenario 2):'; Balances
Write-Host "  prepared transactions left on shard1: $(Scalar 5441 'SELECT count(*) FROM pg_prepared_xacts')"

Write-Host "`n=== Scenario 3: coordinator crashes between the phases (the in-doubt problem) ==="
Run 5441 "BEGIN; UPDATE wallets_s SET balance = balance - 100 WHERE id = $a; PREPARE TRANSACTION 'xfer-3-shard1';" | Out-Null
Write-Host '  The coordinator "dies" now. The prepared transaction survives, holds the lock, and survives a server restart:'
Show-Sql -Port 5441 -Db copay_shard -Sql "SELECT gid, prepared, owner FROM pg_prepared_xacts"
Write-Host '  Any other writer of that wallet is blocked:'
Run 5441 "SET lock_timeout = '2s'; UPDATE wallets_s SET balance = balance WHERE id = $a;" | ForEach-Object { "    $_" }
Write-Host '  Recovery: a person or a recovery process must decide commit or rollback. Here we roll back:'
Run 5441 "ROLLBACK PREPARED 'xfer-3-shard1'" | Out-Null
Balances
Write-Host "`nLesson: 2PC gives atomicity across shards but blocks resources while in doubt. Prepared transactions must be monitored (pg_prepared_xacts)."
