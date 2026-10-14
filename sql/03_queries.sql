USE canteen_db;
-- Q1 JOIN: order details with customer, item and line total
SELECT o.order_id, COALESCE(c.name,'Walk-in') AS customer, f.name AS item, oi.quantity, oi.quantity*oi.unit_price AS line_total
FROM orders o LEFT JOIN customer c ON c.customer_id=o.customer_id
JOIN order_item oi ON oi.order_id=o.order_id JOIN food_item f ON f.item_id=oi.item_id ORDER BY o.order_id;
-- Q2 AGGREGATE + HAVING: customers who spent more than 200
SELECT c.name, SUM(b.total) AS spent FROM customer c JOIN orders o ON o.customer_id=c.customer_id
JOIN bill b ON b.order_id=o.order_id GROUP BY c.customer_id, c.name HAVING SUM(b.total) > 200;
-- Q3 SUBQUERY: items priced above the average menu price
SELECT name, price FROM food_item WHERE price > (SELECT AVG(price) FROM food_item);
-- Q4 NESTED / NOT EXISTS: items never ordered
SELECT name FROM food_item f WHERE NOT EXISTS (SELECT 1 FROM order_item oi WHERE oi.item_id=f.item_id);
-- Q5 NESTED IN: orders containing any Beverage
SELECT order_id FROM orders WHERE order_id IN (
  SELECT oi.order_id FROM order_item oi JOIN food_item f ON f.item_id=oi.item_id
  JOIN category c ON c.category_id=f.category_id WHERE c.name='Beverages');
-- Q6 Unpaid bills with amount due
SELECT b.bill_id, b.order_id, b.total, b.total - COALESCE(SUM(p.amount),0) AS due
FROM bill b LEFT JOIN payment p ON p.bill_id=b.bill_id GROUP BY b.bill_id, b.order_id, b.total
HAVING due > 0;
-- Q7 Low-stock ingredients
SELECT name, stock_qty, reorder_level FROM ingredient WHERE stock_qty <= reorder_level;
-- Q8 Payment method split
SELECT method, COUNT(*) AS payments, SUM(amount) AS amount FROM payment GROUP BY method;
-- Reports via views
SELECT * FROM v_daily_sales;
SELECT * FROM v_popular_items ORDER BY qty_sold DESC;
SELECT * FROM v_category_sales;
SELECT * FROM v_pending_orders;
SELECT * FROM v_ingredient_consumption;
SELECT * FROM v_cancellations;
SELECT * FROM v_revenue;
-- Business-rule tests (each should FAIL with a clear message)
-- INSERT INTO order_item(order_id,item_id,quantity) VALUES (7,10,1);   -- unavailable item
-- INSERT INTO order_item(order_id,item_id,quantity) VALUES (7,1,0);    -- quantity must be > 0
-- UPDATE orders SET status='SERVED' WHERE order_id=7;                  -- invalid transition
-- INSERT INTO payment(bill_id,amount) VALUES (6,99999);                -- payment limit
