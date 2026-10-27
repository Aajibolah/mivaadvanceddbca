-- Q11 The two columns the app needs for one lender's fundings. A covering index
-- (INCLUDE) can answer this from the index alone (Index Only Scan). Parameters: :lender_id
SELECT loan_request_id, amount
  FROM loan_fundings
 WHERE lender_id = :lender_id;
