-- Q2 Open marketplace listing with filters, newest first, with the borrower trust score.
-- The hottest read in the product: every lender opens this screen.
SELECT r.id,
       r.amount,
       r.amount - r.funded_amount AS remaining,
       r.purpose,
       r.tenor_weeks,
       r.interest_rate_pct,
       r.expires_at,
       ts.score AS borrower_trust_score
  FROM loan_requests r
  LEFT JOIN trust_scores ts ON ts.user_id = r.borrower_id
 WHERE r.status = 'OPEN'
   AND r.expires_at > :'as_of_ts'::timestamptz
   AND r.amount BETWEEN 50000 AND 500000
   AND r.tenor_weeks <= 26
 ORDER BY r.created_at DESC
 LIMIT 20;
