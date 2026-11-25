-- Q10 Scholarship Application Assessment (PostgreSQL)

-- (a) Tables
CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id SERIAL PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id),
    age_at_application INT NOT NULL CHECK (age_at_application > 0),
    monthly_income DECIMAL(12, 2) NOT NULL CHECK (monthly_income >= 0),
    average_mark DECIMAL(5, 2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on DATE NOT NULL,
    status VARCHAR(10) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id SERIAL PRIMARY KEY,
    application_id INT NOT NULL REFERENCES applications(application_id),
    old_status VARCHAR(10) NOT NULL,
    new_status VARCHAR(10) NOT NULL,
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO students (student_number, full_name) VALUES
('SC001', 'Ngosa Mwamba'),
('SC002', 'Bwalya Kapeya'),
('SC003', 'Tiza Phiri');

INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
(1, 20, 2000, 85.00, CURRENT_DATE - 9),   -- qualifies
(1, 18, 3000, 70.00, CURRENT_DATE - 8),   -- boundary, qualifies
(2, 25, 1500, 90.00, CURRENT_DATE - 7),   -- boundary, qualifies
(2, 26, 1000, 80.00, CURRENT_DATE - 6),   -- too old
(3, 22, 3001, 75.00, CURRENT_DATE - 5),   -- income too high
(3, 21, 2000, 69.99, CURRENT_DATE - 4);   -- mark too low

-- (b) Function
CREATE FUNCTION fn_scholarship_eligible(p_age INT, p_income DECIMAL, p_mark DECIMAL)
RETURNS BOOLEAN AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Inputs must not be NULL';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive';
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income cannot be negative';
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100';
    END IF;
    RETURN p_age BETWEEN 18 AND 25 AND p_income <= 3000 AND p_mark >= 70;
END;
$$ LANGUAGE plpgsql;

SELECT fn_scholarship_eligible(18, 3000, 70);    -- true
SELECT fn_scholarship_eligible(26, 1000, 90);    -- false

-- (c) Procedure
CREATE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_age INT;
    v_income DECIMAL;
    v_mark DECIMAL;
    v_status VARCHAR(10);
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
    INTO v_age, v_income, v_mark, v_status
    FROM applications WHERE application_id = p_application_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Application % does not exist', p_application_id;
    END IF;
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed', p_application_id;
    END IF;

    UPDATE applications
    SET status = CASE WHEN fn_scholarship_eligible(v_age, v_income, v_mark)
                      THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$;

-- (d) Trigger
CREATE FUNCTION trg_decision_audit() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status)
    VALUES (OLD.application_id, OLD.status, NEW.status);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_applications_update
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_decision_audit();

CALL pr_assess_application(1);

-- these should fail
CALL pr_assess_application(1);     -- already assessed
CALL pr_assess_application(999);   -- does not exist

-- (e) View (income is left out on purpose)
CREATE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- (f) Index (status first, then the date range)
CREATE INDEX idx_applications_status_date ON applications (status, submitted_on);

EXPLAIN SELECT * FROM applications
WHERE status = 'PENDING' AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

-- (g) Scheduled job
CREATE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE rec RECORD;
BEGIN
    FOR rec IN SELECT application_id FROM applications WHERE status = 'PENDING' LOOP
        CALL pr_assess_application(rec.application_id);
    END LOOP;
END;
$$;

CALL pr_assess_pending();
CALL pr_assess_pending();   -- second run finds nothing pending

SELECT application_id, status FROM applications ORDER BY application_id;
SELECT * FROM decision_audit;
SELECT * FROM v_approved_applicants;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('assess_pending', '0 8 * * 1', 'CALL pr_assess_pending()');
