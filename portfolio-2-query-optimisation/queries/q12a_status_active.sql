-- Q12a An index that does NOT help: about 97 percent of users are ACTIVE.
-- Reading 97 percent of a table through an index means jumping around the heap for
-- almost every row, which costs more than one sequential pass. Expect a Seq Scan
-- even after idx_users_status exists.
SELECT count(*), min(created_at) FROM users WHERE status = 'ACTIVE';
