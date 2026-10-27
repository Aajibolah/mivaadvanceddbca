-- Q5 Borrowers ranked by repayment rate, using window functions (rank, ntile).
WITH per_borrower AS (
    SELECT l.borrower_id,
           count(*) FILTER (WHERE s.status = 'PAID') AS paid,
           count(*)                                  AS due
      FROM repayment_schedules s
      JOIN loans l ON l.id = s.loan_id
     WHERE s.due_date < :'as_of'::date
     GROUP BY l.borrower_id
    HAVING count(*) >= 10
)
SELECT borrower_id,
       paid,
       due,
       round(100.0 * paid / due, 1)                               AS repayment_rate_pct,
       rank()    OVER (ORDER BY paid::numeric / due DESC, due DESC) AS rnk,
       ntile(10) OVER (ORDER BY paid::numeric / due DESC)         AS decile
  FROM per_borrower
 ORDER BY rnk
 LIMIT 20;
