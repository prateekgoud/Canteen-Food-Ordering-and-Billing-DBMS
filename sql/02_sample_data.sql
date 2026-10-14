USE canteen_db;
INSERT INTO app_user(username, role) VALUES ('admin','ADMIN'),('cashier1','CASHIER'),('chef1','KITCHEN');
INSERT INTO category(name) VALUES ('Breakfast'),('Meals'),('Snacks'),('Beverages');
INSERT INTO food_item(category_id,name,price,is_available) VALUES
 (1,'Idli',30,TRUE),(1,'Masala Dosa',60,TRUE),(2,'Veg Thali',120,TRUE),(2,'Chicken Biryani',150,TRUE),
 (3,'Samosa',20,TRUE),(3,'Veg Burger',70,TRUE),(3,'French Fries',60,TRUE),
 (4,'Tea',15,TRUE),(4,'Cold Coffee',60,TRUE),(4,'Fresh Lime Soda',40,FALSE);
INSERT INTO ingredient(name,unit,stock_qty,reorder_level) VALUES
 ('Rice','kg',50,10),('Urad Dal','kg',30,5),('Potato','kg',40,8),('Chicken','kg',10,5),
 ('Milk','l',40,10),('Tea Powder','kg',5,1),('Coffee Powder','kg',5,1),('Flour','kg',40,8),
 ('Cooking Oil','l',30,6),('Burger Bun','pcs',100,20),('Vegetables','kg',30,6);
INSERT INTO recipe(item_id,ingredient_id,qty_per_unit) VALUES
 (1,1,0.08),(1,2,0.04),
 (2,1,0.10),(2,2,0.05),(2,3,0.10),(2,9,0.02),
 (3,1,0.20),(3,11,0.20),(3,8,0.10),
 (4,1,0.20),(4,4,0.25),(4,9,0.03),
 (5,8,0.05),(5,3,0.08),(5,9,0.03),
 (6,10,1),(6,11,0.10),(6,9,0.01),
 (7,3,0.20),(7,9,0.05),
 (8,5,0.10),(8,6,0.005),
 (9,5,0.20),(9,7,0.01);
INSERT INTO customer(name,phone) VALUES
 ('Aarav Reddy','9000000001'),('Sneha Rao','9000000002'),('Karthik Nair','9000000003'),('Divya Sharma','9000000004');

INSERT INTO orders(customer_id,order_time) VALUES
 (1,'2026-10-07 09:10:00'),(2,'2026-10-07 13:05:00'),(NULL,'2026-10-08 11:30:00'),
 (3,'2026-10-08 13:15:00'),(1,'2026-10-09 09:00:00'),(4,'2026-10-12 13:20:00'),
 (2,'2026-10-13 10:00:00'),(NULL,'2026-10-13 10:05:00'),(3,'2026-10-13 10:10:00');
INSERT INTO order_item(order_id,item_id,quantity) VALUES
 (1,1,3),(1,8,2),(2,3,1),(2,4,2),(3,5,4),(3,8,2),(4,4,1),(4,9,1),
 (5,2,2),(5,8,2),(6,6,2),(6,7,1),(7,4,2),(8,9,2),(9,2,1);

-- move orders through the workflow (triggers deduct ingredients)
UPDATE orders SET status='PREPARING' WHERE order_id IN (1,2,3,4,5,6,9);
UPDATE orders SET status='READY'     WHERE order_id IN (1,2,3,4,5,6);
UPDATE orders SET status='SERVED'    WHERE order_id IN (1,2,3,4,5,6);
UPDATE orders SET status='CANCELLED' WHERE order_id = 8;

-- bills for served orders (5% tax)
INSERT INTO bill(order_id,subtotal,tax,total,bill_time)
SELECT o.order_id, x.s, ROUND(x.s*0.05,2), x.s + ROUND(x.s*0.05,2), o.order_time + INTERVAL 30 MINUTE
FROM orders o JOIN (SELECT order_id, SUM(quantity*unit_price) s FROM order_item GROUP BY order_id) x
  ON x.order_id = o.order_id
WHERE o.order_id <= 6;

INSERT INTO payment(bill_id,amount,method,paid_at) VALUES
 (1,126.00,'CASH','2026-10-07 09:40:00'),
 (2,441.00,'UPI','2026-10-07 13:35:00'),
 (3,115.50,'CASH','2026-10-08 12:00:00'),
 (4,220.50,'CARD','2026-10-08 13:45:00'),
 (5,157.50,'UPI','2026-10-09 09:30:00');   -- bill 6 left UNPAID for demo
