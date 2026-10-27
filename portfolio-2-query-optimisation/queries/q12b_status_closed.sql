-- Q12b Same index, selective value: only a small fraction of users are CLOSED,
-- so the index can win here.
SELECT count(*), min(created_at) FROM users WHERE status = 'CLOSED';
