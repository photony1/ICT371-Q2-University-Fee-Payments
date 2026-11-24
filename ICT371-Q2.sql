-- ICT371 Question 2: University Fee Payments (PostgreSQL)
DROP VIEW IF EXISTS v_fee_balances;
DROP TABLE IF EXISTS payment_audit, payments, daily_collections, students CASCADE;

-- (a) Tables and constraints
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INT NOT NULL REFERENCES payments(payment_id),
    student_id INT NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL,
    logged_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INT NOT NULL DEFAULT 0,
    total_amount    NUMERIC(12,2) NOT NULL DEFAULT 0.00
);

-- (b) Function: compute outstanding fee balance
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC(12,2) LANGUAGE plpgsql AS $$
DECLARE
    v_fee_due NUMERIC(12,2);
    v_paid    NUMERIC(12,2);
BEGIN
    SELECT fee_due INTO v_fee_due FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student ID: %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0.00) INTO v_paid FROM payments WHERE student_id = p_student_id;
    RETURN v_fee_due - v_paid;
END;
$$;

-- (c) Procedure: receive payment without altering fee_due
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be greater than zero.';
    END IF;
    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date cannot be NULL.';
    END IF;

    v_balance := fn_fee_balance(p_student_id);
    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Overpayment rejected. Amount (%) exceeds balance (%).', p_amount, v_balance;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

-- (d) Trigger: audit every inserted payment
CREATE OR REPLACE FUNCTION fn_trg_payment_audit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, CURRENT_TIMESTAMP);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payments_after_insert
AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION fn_trg_payment_audit();

-- (a) Seed data: 3 students (one with no payments) and 6 payments
INSERT INTO students (student_number, full_name, fee_due) VALUES
('2024001', 'Chanda Mwila',   12000.00),
('2024002', 'Bwalya Tembo',   10000.00),
('2024003', 'Mutale Phiri',    8500.00); -- No payments initially

CALL pr_receive_payment(1, 3000.00, CURRENT_DATE - 5);
CALL pr_receive_payment(1, 2500.00, CURRENT_DATE - 2);
CALL pr_receive_payment(1, 1500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 4000.00, CURRENT_DATE - 4);
CALL pr_receive_payment(2, 3000.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 3000.00, CURRENT_DATE); -- Fully settled

-- (e) View: students who still owe fees
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name, fn_fee_balance(s.student_id) AS outstanding_balance
FROM students s
WHERE fn_fee_balance(s.student_id) > 0;

SELECT * FROM v_fee_balances;

-- (f) Index & EXPLAIN
-- Justification: Composite index on (student_id, paid_on) optimizes equality lookup on student_id
-- paired with a date range scan on paid_on.
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);

EXPLAIN ANALYZE
SELECT payment_id, amount, paid_on
FROM payments
WHERE student_id = 1 AND paid_on BETWEEN CURRENT_DATE - 10 AND CURRENT_DATE;

-- (g) Scheduled job: daily collections
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0.00)
    FROM payments WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count,
        total_amount = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_collections(CURRENT_DATE - 1);

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_daily_collections', '0 1 * * *', $$CALL pr_refresh_collections(CURRENT_DATE - 1);$$);
