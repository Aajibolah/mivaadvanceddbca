-- Q8 Support search: find a user by part of the name (case insensitive, substring).
SELECT id, full_name, email
  FROM users
 WHERE full_name ILIKE '%unle bal%'
 LIMIT 20;
