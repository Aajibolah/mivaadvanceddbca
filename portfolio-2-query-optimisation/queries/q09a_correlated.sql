-- Q9a Lenders who funded more than NGN 1,000,000 in total: correlated subquery version.
SELECT u.id, u.full_name,
       (SELECT sum(f.amount) FROM loan_fundings f WHERE f.lender_id = u.id) AS total_funded
  FROM users u
 WHERE (SELECT sum(f.amount) FROM loan_fundings f WHERE f.lender_id = u.id) > 1000000
 ORDER BY total_funded DESC
 LIMIT 20;
