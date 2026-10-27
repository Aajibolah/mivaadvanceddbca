-- Q6 Monthly disbursement and repayment totals using CTEs, with a running total.
WITH disb AS (
    SELECT date_trunc('month', disbursed_at) AS m, count(*) AS loans, sum(principal) AS disbursed
      FROM loans GROUP BY 1
), rep AS (
    SELECT date_trunc('month', paid_at) AS m, count(*) AS repayments, sum(amount) AS repaid
      FROM repayments GROUP BY 1
)
SELECT to_char(COALESCE(d.m, r.m), 'YYYY-MM') AS month,
       d.loans,
       d.disbursed,
       r.repayments,
       r.repaid,
       sum(COALESCE(d.disbursed, 0)) OVER (ORDER BY COALESCE(d.m, r.m)) AS cumulative_disbursed
  FROM disb d
  FULL JOIN rep r ON r.m = d.m
 ORDER BY COALESCE(d.m, r.m);
