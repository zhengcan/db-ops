CREATE TABLE products (
  id SERIAL PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  price NUMERIC(10,2) NOT NULL,
  price_with_tax NUMERIC(10,2) GENERATED ALWAYS AS (price * 1.1) STORED,
  thumbnail BYTEA
);

INSERT INTO products (name, price, thumbnail) VALUES
  ('Widget', 9.99, '\x89504e470d0a1a0a'),
  ('Gadget', 19.99, '\xffd8ffe000104a46'),
  ('Doohickey', 5.49, NULL);

CREATE VIEW expensive_products AS
  SELECT id, name, price FROM products WHERE price > 10;

CREATE TABLE audit_log (
  id SERIAL PRIMARY KEY,
  message VARCHAR(255),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE OR REPLACE FUNCTION add_product(p_name VARCHAR(100), p_price NUMERIC(10,2))
RETURNS VOID AS $$
BEGIN
  INSERT INTO products (name, price) VALUES (p_name, p_price);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION log_product_insert() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO audit_log (message) VALUES ('Inserted product: ' || NEW.name);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER products_after_insert
AFTER INSERT ON products
FOR EACH ROW
EXECUTE FUNCTION log_product_insert();

-- Standalone sequence in addition to the products_id_seq that SERIAL
-- already created implicitly, so at least one sequence exists independent
-- of any table's primary key.
CREATE SEQUENCE order_number_seq START 1000;
