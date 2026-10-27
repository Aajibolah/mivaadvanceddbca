-- Q9b Same question as Q9a, written as a join with a single aggregation.
SELECT u.id, u.full_name, f.total_funded
  FROM (SELECT lender_id, sum(amount) AS total_funded
          FROM loan_fundings
         GROUP BY lender_id
        HAVING sum(amount) > 1000000) f
  JOIN users u ON u.id = f.lender_id
 ORDER BY f.total_funded DESC
 LIMIT 20;
