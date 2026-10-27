-- Q10 Support lookup by exact name regardless of case. Wrapping the column in lower()
-- stops a plain index on full_name from being used, so an expression index is needed.
SELECT id, full_name, email
  FROM users
 WHERE lower(full_name) = lower('Kunle Balogun');
