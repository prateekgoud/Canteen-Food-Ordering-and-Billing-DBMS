-- Canteen Food Ordering & Billing DBMS (MySQL 8.0.16+)
DROP DATABASE IF EXISTS canteen_db;
CREATE DATABASE canteen_db;
USE canteen_db;

CREATE TABLE app_user (
  user_id INT AUTO_INCREMENT PRIMARY KEY,
  username VARCHAR(30) NOT NULL UNIQUE,
  role ENUM('ADMIN','CASHIER','KITCHEN') NOT NULL DEFAULT 'CASHIER'
);
CREATE TABLE category (
  category_id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(40) NOT NULL UNIQUE
);
CREATE TABLE food_item (
  item_id INT AUTO_INCREMENT PRIMARY KEY,
  category_id INT NOT NULL,
  name VARCHAR(60) NOT NULL UNIQUE,
  price DECIMAL(8,2) NOT NULL CHECK (price > 0),
  is_available BOOLEAN NOT NULL DEFAULT TRUE,
  FOREIGN KEY (category_id) REFERENCES category(category_id)
);
CREATE TABLE ingredient (
  ingredient_id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(60) NOT NULL UNIQUE,
  unit VARCHAR(10) NOT NULL,
  stock_qty DECIMAL(10,2) NOT NULL DEFAULT 0 CHECK (stock_qty >= 0),
  reorder_level DECIMAL(10,2) NOT NULL DEFAULT 0 CHECK (reorder_level >= 0)
);
CREATE TABLE recipe (
  item_id INT NOT NULL,
  ingredient_id INT NOT NULL,
  qty_per_unit DECIMAL(8,3) NOT NULL CHECK (qty_per_unit > 0),
  PRIMARY KEY (item_id, ingredient_id),
  FOREIGN KEY (item_id) REFERENCES food_item(item_id) ON DELETE CASCADE,
  FOREIGN KEY (ingredient_id) REFERENCES ingredient(ingredient_id)
);
CREATE TABLE customer (
  customer_id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(60) NOT NULL,
  phone VARCHAR(10) UNIQUE CHECK (phone REGEXP '^[0-9]{10}$')
);
CREATE TABLE orders (
  order_id INT AUTO_INCREMENT PRIMARY KEY,
  customer_id INT NULL,                      -- NULL = walk-in
  order_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  status ENUM('PLACED','PREPARING','READY','SERVED','CANCELLED') NOT NULL DEFAULT 'PLACED',
  FOREIGN KEY (customer_id) REFERENCES customer(customer_id) ON DELETE SET NULL
);
CREATE TABLE order_item (
  order_id INT NOT NULL,
  item_id INT NOT NULL,
  quantity INT NOT NULL CHECK (quantity > 0),
  unit_price DECIMAL(8,2) NOT NULL DEFAULT 0 CHECK (unit_price >= 0),
  PRIMARY KEY (order_id, item_id),
  FOREIGN KEY (order_id) REFERENCES orders(order_id) ON DELETE CASCADE,
  FOREIGN KEY (item_id) REFERENCES food_item(item_id)
);
CREATE TABLE kitchen_task (
  task_id INT AUTO_INCREMENT PRIMARY KEY,
  order_id INT NOT NULL,
  item_id INT NOT NULL,
  status ENUM('PENDING','COOKING','DONE') NOT NULL DEFAULT 'PENDING',
  UNIQUE (order_id, item_id),
  FOREIGN KEY (order_id, item_id) REFERENCES order_item(order_id, item_id) ON DELETE CASCADE
);
CREATE TABLE bill (
  bill_id INT AUTO_INCREMENT PRIMARY KEY,
  order_id INT NOT NULL UNIQUE,
  subtotal DECIMAL(10,2) NOT NULL CHECK (subtotal > 0),
  tax DECIMAL(10,2) NOT NULL DEFAULT 0 CHECK (tax >= 0),
  total DECIMAL(10,2) NOT NULL,
  bill_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  status ENUM('UNPAID','PAID') NOT NULL DEFAULT 'UNPAID',
  CHECK (total = subtotal + tax),
  FOREIGN KEY (order_id) REFERENCES orders(order_id)
);
CREATE TABLE payment (
  payment_id INT AUTO_INCREMENT PRIMARY KEY,
  bill_id INT NOT NULL,
  amount DECIMAL(10,2) NOT NULL CHECK (amount > 0),
  method ENUM('CASH','UPI','CARD') NOT NULL DEFAULT 'CASH',
  paid_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (bill_id) REFERENCES bill(bill_id)
);
CREATE TABLE stock_txn (
  txn_id INT AUTO_INCREMENT PRIMARY KEY,
  ingredient_id INT NOT NULL,
  change_qty DECIMAL(10,2) NOT NULL,         -- negative = stock out
  txn_type ENUM('ORDER_USE','ORDER_RETURN','ISSUE','RESTOCK') NOT NULL,
  order_id INT NULL,
  txn_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (ingredient_id) REFERENCES ingredient(ingredient_id)
);

-- Indexes for frequently searched columns
CREATE INDEX idx_orders_time     ON orders(order_time);
CREATE INDEX idx_orders_status   ON orders(status);
CREATE INDEX idx_orders_customer ON orders(customer_id);
CREATE INDEX idx_bill_time       ON bill(bill_time);
CREATE INDEX idx_payment_bill    ON payment(bill_id);
CREATE INDEX idx_stock_ing       ON stock_txn(ingredient_id);

DELIMITER $$

-- Rule: no unavailable items; items only added to PLACED orders; price frozen at order time
CREATE TRIGGER trg_oi_bi BEFORE INSERT ON order_item FOR EACH ROW
BEGIN
  DECLARE v_av BOOLEAN; DECLARE v_p DECIMAL(8,2); DECLARE v_st VARCHAR(15);
  SELECT is_available, price INTO v_av, v_p FROM food_item WHERE item_id = NEW.item_id;
  IF v_av IS NULL OR v_av = FALSE THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Item is unavailable and cannot be ordered';
  END IF;
  SELECT status INTO v_st FROM orders WHERE order_id = NEW.order_id;
  IF v_st <> 'PLACED' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Items can only be added to a PLACED order';
  END IF;
  SET NEW.unit_price = v_p;
END$$

CREATE TRIGGER trg_oi_ai AFTER INSERT ON order_item FOR EACH ROW
BEGIN
  INSERT INTO kitchen_task(order_id, item_id) VALUES (NEW.order_id, NEW.item_id);
END$$

-- Rule: valid status transitions; at least one item per order before kitchen starts
CREATE TRIGGER trg_ord_bu BEFORE UPDATE ON orders FOR EACH ROW
BEGIN
  DECLARE n INT;
  IF NEW.status <> OLD.status THEN
    IF NOT ((OLD.status = 'PLACED'    AND NEW.status IN ('PREPARING','CANCELLED'))
         OR (OLD.status = 'PREPARING' AND NEW.status IN ('READY','CANCELLED'))
         OR (OLD.status = 'READY'     AND NEW.status = 'SERVED')) THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid order status transition';
    END IF;
    IF NEW.status = 'PREPARING' THEN
      SELECT COUNT(*) INTO n FROM order_item WHERE order_id = OLD.order_id;
      IF n = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'An order must contain at least one item';
      END IF;
    END IF;
  END IF;
END$$

-- Ingredient consumption: deduct on PREPARING, restore if cancelled while preparing
CREATE TRIGGER trg_ord_au AFTER UPDATE ON orders FOR EACH ROW
BEGIN
  IF NEW.status <> OLD.status THEN
    IF NEW.status = 'PREPARING' THEN
      UPDATE ingredient i JOIN (
        SELECT r.ingredient_id, SUM(r.qty_per_unit * oi.quantity) q
        FROM order_item oi JOIN recipe r ON r.item_id = oi.item_id
        WHERE oi.order_id = NEW.order_id GROUP BY r.ingredient_id) u
        ON u.ingredient_id = i.ingredient_id
      SET i.stock_qty = i.stock_qty - u.q;
      INSERT INTO stock_txn(ingredient_id, change_qty, txn_type, order_id)
        SELECT r.ingredient_id, -SUM(r.qty_per_unit * oi.quantity), 'ORDER_USE', NEW.order_id
        FROM order_item oi JOIN recipe r ON r.item_id = oi.item_id
        WHERE oi.order_id = NEW.order_id GROUP BY r.ingredient_id;
      UPDATE kitchen_task SET status = 'COOKING' WHERE order_id = NEW.order_id;
    ELSEIF NEW.status = 'READY' THEN
      UPDATE kitchen_task SET status = 'DONE' WHERE order_id = NEW.order_id;
    ELSEIF NEW.status = 'CANCELLED' AND OLD.status = 'PREPARING' THEN
      UPDATE ingredient i JOIN (
        SELECT r.ingredient_id, SUM(r.qty_per_unit * oi.quantity) q
        FROM order_item oi JOIN recipe r ON r.item_id = oi.item_id
        WHERE oi.order_id = NEW.order_id GROUP BY r.ingredient_id) u
        ON u.ingredient_id = i.ingredient_id
      SET i.stock_qty = i.stock_qty + u.q;
      INSERT INTO stock_txn(ingredient_id, change_qty, txn_type, order_id)
        SELECT r.ingredient_id, SUM(r.qty_per_unit * oi.quantity), 'ORDER_RETURN', NEW.order_id
        FROM order_item oi JOIN recipe r ON r.item_id = oi.item_id
        WHERE oi.order_id = NEW.order_id GROUP BY r.ingredient_id;
    END IF;
  END IF;
END$$

-- Rule: payment limit (<= 10000 per transaction) and cannot exceed amount due
CREATE TRIGGER trg_pay_bi BEFORE INSERT ON payment FOR EACH ROW
BEGIN
  DECLARE t DECIMAL(10,2); DECLARE paid DECIMAL(10,2);
  SELECT total INTO t FROM bill WHERE bill_id = NEW.bill_id;
  SELECT COALESCE(SUM(amount), 0) INTO paid FROM payment WHERE bill_id = NEW.bill_id;
  IF NEW.amount > 10000 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment exceeds the per-transaction limit of 10000';
  END IF;
  IF paid + NEW.amount > t THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment exceeds the amount due on this bill';
  END IF;
END$$

CREATE TRIGGER trg_pay_ai AFTER INSERT ON payment FOR EACH ROW
BEGIN
  UPDATE bill SET status = 'PAID'
  WHERE bill_id = NEW.bill_id
    AND total <= (SELECT SUM(amount) FROM payment WHERE bill_id = NEW.bill_id);
END$$

-- Billing procedure: 5% tax; no bill for cancelled / empty orders
CREATE PROCEDURE generate_bill(IN p_order INT)
BEGIN
  DECLARE s DECIMAL(10,2); DECLARE st VARCHAR(15); DECLARE tx DECIMAL(10,2);
  SELECT status INTO st FROM orders WHERE order_id = p_order;
  IF st IS NULL OR st = 'CANCELLED' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Order not found or cancelled - cannot bill';
  END IF;
  SELECT SUM(quantity * unit_price) INTO s FROM order_item WHERE order_id = p_order;
  IF s IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Order has no items - cannot bill';
  END IF;
  SET tx = ROUND(s * 0.05, 2);
  INSERT INTO bill(order_id, subtotal, tax, total) VALUES (p_order, s, tx, s + tx);
END$$

DELIMITER ;

-- Reporting views
CREATE VIEW v_daily_sales AS
  SELECT DATE(bill_time) AS sale_date, COUNT(*) AS bills, SUM(total) AS revenue
  FROM bill GROUP BY DATE(bill_time);

CREATE VIEW v_popular_items AS
  SELECT f.name, SUM(oi.quantity) AS qty_sold, SUM(oi.quantity * oi.unit_price) AS revenue
  FROM order_item oi JOIN food_item f ON f.item_id = oi.item_id
  JOIN orders o ON o.order_id = oi.order_id
  WHERE o.status <> 'CANCELLED'
  GROUP BY f.item_id, f.name;

CREATE VIEW v_category_sales AS
  SELECT c.name AS category, SUM(oi.quantity) AS qty_sold, SUM(oi.quantity * oi.unit_price) AS revenue
  FROM order_item oi JOIN food_item f ON f.item_id = oi.item_id
  JOIN category c ON c.category_id = f.category_id
  JOIN orders o ON o.order_id = oi.order_id
  WHERE o.status <> 'CANCELLED'
  GROUP BY c.category_id, c.name;

CREATE VIEW v_pending_orders AS
  SELECT o.order_id, o.order_time, o.status, COALESCE(c.name, 'Walk-in') AS customer,
         GROUP_CONCAT(CONCAT(f.name, ' x', oi.quantity) SEPARATOR ', ') AS items
  FROM orders o LEFT JOIN customer c ON c.customer_id = o.customer_id
  JOIN order_item oi ON oi.order_id = o.order_id
  JOIN food_item f ON f.item_id = oi.item_id
  WHERE o.status IN ('PLACED','PREPARING','READY')
  GROUP BY o.order_id, o.order_time, o.status, c.name;

CREATE VIEW v_ingredient_consumption AS
  SELECT i.name, i.unit, COALESCE(-SUM(t.change_qty), 0) AS consumed, i.stock_qty, i.reorder_level
  FROM ingredient i
  LEFT JOIN stock_txn t ON t.ingredient_id = i.ingredient_id
       AND t.txn_type IN ('ORDER_USE','ORDER_RETURN','ISSUE')
  GROUP BY i.ingredient_id, i.name, i.unit, i.stock_qty, i.reorder_level;

CREATE VIEW v_cancellations AS
  SELECT o.order_id, o.order_time, COALESCE(c.name, 'Walk-in') AS customer,
         SUM(oi.quantity * oi.unit_price) AS lost_value
  FROM orders o LEFT JOIN customer c ON c.customer_id = o.customer_id
  JOIN order_item oi ON oi.order_id = o.order_id
  WHERE o.status = 'CANCELLED'
  GROUP BY o.order_id, o.order_time, c.name;

CREATE VIEW v_revenue AS
  SELECT b.billed, p.collected, b.billed - p.collected AS outstanding
  FROM (SELECT COALESCE(SUM(total), 0) AS billed FROM bill) b,
       (SELECT COALESCE(SUM(amount), 0) AS collected FROM payment) p;
