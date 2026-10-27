-- =============================================================================
-- Replication checks. Run the parts marked PRIMARY against port 5433 and the
-- parts marked REPLICA against port 5434, for example:
--   psql -h localhost -p 5433 -d copay -f replication_checks.sql   (PRIMARY parts work; REPLICA parts error)
-- The guide (README.md) lists the exact commands in order.
-- =============================================================================

-- ---------- PRIMARY: who is connected and how far behind are they ----------
-- state = streaming means WAL is flowing. The *_lag columns show write/flush/replay delay.
SELECT application_name, state, sync_state,
       pg_wal_lsn_diff(sent_lsn, replay_lsn) AS replay_lag_bytes,
       write_lag, flush_lag, replay_lag
  FROM pg_stat_replication;

-- Replication slot: guarantees the primary keeps WAL the replica has not received yet.
SELECT slot_name, slot_type, active, restart_lsn FROM pg_replication_slots;

-- ---------- REPLICA: am I a standby, and how stale is my data ----------
SELECT pg_is_in_recovery() AS is_replica,
       pg_last_wal_receive_lsn() AS received_lsn,
       pg_last_wal_replay_lsn() AS replayed_lsn,
       pg_last_xact_replay_timestamp() AS last_replayed_commit_time,
       now() - pg_last_xact_replay_timestamp() AS apparent_lag;
