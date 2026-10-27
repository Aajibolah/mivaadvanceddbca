-- Q3 Lender portfolio summary: joins and aggregates. Parameters: :lender_id
SELECT r.status,
       count(*)                           AS fundings,
       count(DISTINCT f.loan_request_id)  AS requests,
       sum(f.amount)                      AS total_funded,
       round(avg(r.interest_rate_pct), 2) AS avg_interest_pct
  FROM loan_fundings f
  JOIN loan_requests r ON r.id = f.loan_request_id
 WHERE f.lender_id = :lender_id
 GROUP BY r.status
 ORDER BY total_funded DESC;
