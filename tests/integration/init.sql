CREATE TABLE products (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  price DECIMAL(10,2) NOT NULL,
  price_with_tax DECIMAL(10,2) AS (price * 1.1) VIRTUAL,
  name_upper VARCHAR(100) AS (UPPER(name)) STORED,
  thumbnail BLOB
);

INSERT INTO products (name, price, thumbnail) VALUES
  ('Widget', 9.99, UNHEX('89504E470D0A1A0A')),
  ('Gadget', 19.99, UNHEX('FFD8FFE000104A46')),
  ('Doohickey', 5.49, NULL),
  -- Regression case: 4-byte UTF-8 (emoji) must survive backup+restore.
  -- See my-ops.sh's db_mysql()/db_mysqldump() comment for why this needs
  -- --default-character-set=utf8mb4 on every connection, not just the
  -- schema-import one.
  ('🚧 Roadwork 🎉', 3.00, NULL);

CREATE VIEW expensive_products AS
  SELECT id, name, price FROM products WHERE price > 10;

CREATE TABLE audit_log (
  id INT AUTO_INCREMENT PRIMARY KEY,
  message VARCHAR(255),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

DELIMITER $$
CREATE PROCEDURE add_product(IN p_name VARCHAR(100), IN p_price DECIMAL(10,2))
BEGIN
  INSERT INTO products (name, price) VALUES (p_name, p_price);
END$$

CREATE TRIGGER products_after_insert
AFTER INSERT ON products
FOR EACH ROW
BEGIN
  INSERT INTO audit_log (message) VALUES (CONCAT('Inserted product: ', NEW.name));
END$$
DELIMITER ;

SET GLOBAL event_scheduler = ON;

CREATE EVENT cleanup_audit_log
ON SCHEDULE EVERY 1 DAY
DO
  DELETE FROM audit_log WHERE created_at < NOW() - INTERVAL 30 DAY;
