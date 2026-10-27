-- Q4 Overdue repayments report for collections and support.
SELECT l.id                              AS loan_id,
       u.full_name,
       u.phone,
       count(*)                          AS unpaid_instalments,
       sum(s.amount_due - s.amount_paid) AS outstanding,
       min(s.due_date)                   AS oldest_due,
       :'as_of'::date - min(s.due_date)  AS days_late
  FROM repayment_schedules s
  JOIN loans l ON l.id = s.loan_id
  JOIN users u ON u.id = l.borrower_id
 WHERE s.status <> 'PAID'
   AND s.due_date < :'as_of'::date
 GROUP BY l.id, u.full_name, u.phone
 ORDER BY outstanding DESC
 LIMIT 25;
