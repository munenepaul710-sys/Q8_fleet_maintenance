-- =====================================================================
-- ICT371 Advanced Database | Question 8: Transport Fleet Maintenance
-- Dialect: PostgreSQL (PL/pgSQL). Scheduling uses the pg_cron extension.
-- Service is due when current_odometer - last_service_odometer >= 5000.
-- =====================================================================

-- (a) DATABASE AND SEED DATA ------------------------------------------
DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

CREATE TABLE vehicles (
    vehicle_id            SERIAL      PRIMARY KEY,
    registration          VARCHAR(20) NOT NULL UNIQUE,
    current_odometer      INTEGER     NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INTEGER     NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT ck_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL  PRIMARY KEY,
    vehicle_id     INTEGER NOT NULL REFERENCES vehicles (vehicle_id),
    trip_on        DATE    NOT NULL,
    start_odometer INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INTEGER NOT NULL CHECK (end_odometer >= 0)
);

CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles (vehicle_id),
    km_since_service INTEGER NOT NULL,
    flagged_on       DATE    NOT NULL
);

-- Odometer values are the starting positions; the trips below will move them.
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('BAK 1001', 9500, 4000),    -- 5500 since service after the trips: DUE
    ('BAL 2002', 7000, 5000),    -- 3000 since service after the trips: not due
    ('BAM 3003', 4500,    0);    -- exactly 5000 after the trips: DUE (boundary)

-- (b) FUNCTION ---------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_km INTEGER;
BEGIN
    SELECT current_odometer - last_service_odometer INTO v_km
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN v_km >= 5000;
END;
$$;

-- (c) PROCEDURE --------------------------------------------------------
-- The odometer is NOT updated here; the trigger in (d) does that once.
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INTEGER, p_trip_on DATE, p_start INTEGER, p_end INTEGER)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;
    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date and odometer readings must not be NULL';
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'End odometer (%) must be greater than start odometer (%)', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- (d) TRIGGER ----------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current INTEGER;
BEGIN
    -- Lock the vehicle row so concurrent trips cannot share one odometer value
    SELECT current_odometer INTO v_current
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end (%) must exceed start (%)',
                        NEW.end_odometer, NEW.start_odometer;
    END IF;
    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Start odometer % does not match current odometer % of vehicle %',
                        NEW.start_odometer, v_current, NEW.vehicle_id;
    END IF;

    UPDATE vehicles
    SET current_odometer = NEW.end_odometer      -- updated exactly once per trip
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trip_odometer();

-- (a) CONTINUED: SIX TRIPS THROUGH THE PROCEDURE (trigger already installed)
CALL pr_record_trip(1, CURRENT_DATE - 6, 9500, 9800);
CALL pr_record_trip(1, CURRENT_DATE - 3, 9800, 10000);
CALL pr_record_trip(2, CURRENT_DATE - 5, 7000, 7400);
CALL pr_record_trip(2, CURRENT_DATE - 2, 7400, 8000);
CALL pr_record_trip(3, CURRENT_DATE - 4, 4500, 4800);
CALL pr_record_trip(3, CURRENT_DATE - 1, 4800, 5000);

SELECT * FROM vehicles ORDER BY vehicle_id;
SELECT vehicle_id, fn_service_due(vehicle_id) AS service_due FROM vehicles ORDER BY 1;

-- Rejected calls:
-- CALL pr_record_trip(1, CURRENT_DATE, 9999, 10100);   -- start does not match odometer (10000)
-- CALL pr_record_trip(1, CURRENT_DATE, 10000, 10000);  -- end not greater than start
-- CALL pr_record_trip(99, CURRENT_DATE, 0, 10);        -- unknown vehicle

-- (e) VIEW -------------------------------------------------------------
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due;

-- (f) INDEX ------------------------------------------------------------
-- Justification: one vehicle's trips in a date range = equality on
-- vehicle_id plus a range on trip_on. A composite index with the equality
-- column first lets PostgreSQL go directly to that vehicle and read its
-- trips in date order without scanning the whole table.
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);
ANALYZE trips;

SET enable_seqscan = off;   -- only so the plan is visible on a tiny table
EXPLAIN
SELECT *
FROM trips
WHERE vehicle_id = 1
  AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) SCHEDULED JOB ----------------------------------------------------
-- Inserts or updates one alert per due vehicle and deletes alerts for
-- vehicles that are no longer due. The original flagged_on date is kept.
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
    FROM vehicles
    WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service;

    DELETE FROM service_alerts
    WHERE vehicle_id NOT IN (
        SELECT vehicle_id FROM vehicles
        WHERE current_odometer - last_service_odometer >= 5000
    );
END;
$$;

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;

-- Servicing vehicle 1 removes its alert on the next run:
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 1;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;

-- CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'refresh_service_alerts_weekly',
    '0 6 * * 1',                                 -- every Monday at 06:00
    $job$CALL pr_refresh_service_alerts()$job$
);
