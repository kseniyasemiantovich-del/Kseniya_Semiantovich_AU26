-- dvdrental: view + functions + fixes
-- run: psql -d dvdrental -v ON_ERROR_STOP=1 -f dvd_rental_short.sql
-- everything is CREATE OR REPLACE, so it can be rerun


-- ---------- setup ----------
-- default language for new_movie() is missing in dvdrental, add it once
INSERT INTO public.language (name, last_update)
SELECT 'Klingon', now()
WHERE NOT EXISTS (SELECT 1 FROM public.language WHERE name = 'Klingon');


-- =====================================================================
-- TASK 1. View: revenue per category for the current quarter
-- =====================================================================
-- CURRENT_DATE is evaluated on every query, so when a new quarter starts
-- the view moves on by itself. date_trunc('quarter') gives the first day
-- of the quarter (the year is inside that date). The end is start + 3 months
-- and it is excluded (<), so a payment on 1 Apr is not counted in Q1 too.
-- Inner joins: a category without payments has no rows, so it never shows up
-- (no zero rows, no HAVING needed).
-- Not shown: categories with payments only in the previous quarter.
-- Note: the sample data is from 2017 (the 2007 dump has no 2017 data),
-- so the view is empty today - that is correct.

CREATE OR REPLACE VIEW public.sales_revenue_by_category_qtr AS
SELECT c.name        AS category_name,
       SUM(p.amount) AS total_revenue
FROM public.payment AS p
JOIN public.rental AS r        ON r.rental_id = p.rental_id
JOIN public.inventory AS i     ON i.inventory_id = r.inventory_id
JOIN public.film_category AS fc ON fc.film_id = i.film_id
JOIN public.category AS c      ON c.category_id = fc.category_id
WHERE p.payment_date >= date_trunc('quarter', CURRENT_DATE)
  AND p.payment_date <  date_trunc('quarter', CURRENT_DATE) + INTERVAL '3 months'
GROUP BY c.category_id, c.name;

-- test 1 (valid): the view runs; for today it gives 0 rows (no current-quarter data)
SELECT COUNT(*) AS rows_now FROM public.sales_revenue_by_category_qtr;

-- test 2 (edge): a payment from the previous quarter must not show up (rolled back)
BEGIN;
INSERT INTO public.payment (customer_id, staff_id, rental_id, amount, payment_date)
VALUES (1, 1, 1, 9.99, date_trunc('quarter', CURRENT_DATE) - INTERVAL '1 day');
SELECT COUNT(*) AS rows_with_old_payment FROM public.sales_revenue_by_category_qtr; -- expect 0
ROLLBACK;


-- =====================================================================
-- TASK 2. SQL function: same as the view, for any quarter
-- =====================================================================
-- Parameter is one DATE: any day inside the wanted quarter.
-- DEFAULT CURRENT_DATE = no argument means "this quarter" (same as the view).
-- Same logic as the view: date_trunc to the quarter start, end excluded.
-- NULL input: comparisons become NULL, so 0 rows, no error.
-- Impossible date like '2017-02-30' fails before the function runs.
-- SQL functions can't RAISE, so bad input gives an empty result, not an error.
-- Quarter with no payments: 0 rows.

CREATE OR REPLACE FUNCTION public.get_sales_revenue_by_category_qtr(
    p_date DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (category_name TEXT, total_revenue NUMERIC)
LANGUAGE sql
STABLE
AS $$
    SELECT c.name::TEXT, SUM(p.amount)
    FROM public.payment AS p
    JOIN public.rental AS r        ON r.rental_id = p.rental_id
    JOIN public.inventory AS i     ON i.inventory_id = r.inventory_id
    JOIN public.film_category AS fc ON fc.film_id = i.film_id
    JOIN public.category AS c      ON c.category_id = fc.category_id
    WHERE p.payment_date >= date_trunc('quarter', p_date)
      AND p.payment_date <  date_trunc('quarter', p_date) + INTERVAL '3 months'
    GROUP BY c.category_id, c.name;
$$;

-- test 1 (valid): Q1 2017 from the function equals the same query with explicit dates
SELECT
  (SELECT COUNT(*) FROM (
     SELECT * FROM public.get_sales_revenue_by_category_qtr(DATE '2017-02-15')
     EXCEPT
     SELECT c.name, SUM(p.amount)
     FROM public.payment p
     JOIN public.rental r ON r.rental_id = p.rental_id
     JOIN public.inventory i ON i.inventory_id = r.inventory_id
     JOIN public.film_category fc ON fc.film_id = i.film_id
     JOIN public.category c ON c.category_id = fc.category_id
     WHERE p.payment_date >= '2017-01-01' AND p.payment_date < '2017-04-01'
     GROUP BY c.category_id, c.name
  ) x) AS extra_rows;

-- test 2 (edge): NULL date returns no rows
SELECT COUNT(*) AS rows_for_null FROM public.get_sales_revenue_by_category_qtr(NULL::DATE);


-- =====================================================================
-- TASK 3. Most popular film per country (by number of rentals)
-- =====================================================================
-- "Popular" = most rentals in that country (customer -> address -> city -> country).
-- Ties: the alphabetically first title wins, so there is always one row per country.
-- Unknown country name: exception (the name must be spelled right).
-- Country with no rentals: row with NULL title and 0 rentals.
-- NULL or empty array: exception.

CREATE OR REPLACE FUNCTION public.most_popular_films_by_countries(p_countries TEXT[])
RETURNS TABLE (country_name TEXT, film_title TEXT, rental_count BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_unknown TEXT;
BEGIN
    IF p_countries IS NULL OR cardinality(p_countries) = 0 THEN
        RAISE EXCEPTION 'p_countries must be a non-empty array of country names';
    END IF;

    SELECT u.name INTO v_unknown
    FROM unnest(p_countries) AS u(name)
    WHERE NOT EXISTS (SELECT 1 FROM public.country co WHERE co.country = u.name)
    LIMIT 1;

    IF v_unknown IS NOT NULL THEN
        RAISE EXCEPTION 'Unknown country name: %', v_unknown;
    END IF;

    RETURN QUERY
    WITH country_films AS (
        SELECT co.country::TEXT AS c_name, f.title::TEXT AS f_title, COUNT(*) AS c_rentals
        FROM public.rental r
        JOIN public.customer cu ON cu.customer_id = r.customer_id
        JOIN public.address a   ON a.address_id = cu.address_id
        JOIN public.city ci     ON ci.city_id = a.city_id
        JOIN public.country co  ON co.country_id = ci.country_id
        JOIN public.inventory i ON i.inventory_id = r.inventory_id
        JOIN public.film f      ON f.film_id = i.film_id
        WHERE co.country = ANY (p_countries)
        GROUP BY co.country, f.film_id, f.title
    ),
    top_film AS (
        SELECT cf.c_name, cf.f_title, cf.c_rentals
        FROM country_films cf
        WHERE cf.c_rentals = (SELECT MAX(x.c_rentals) FROM country_films x WHERE x.c_name = cf.c_name)
          AND cf.f_title  = (SELECT MIN(y.f_title) FROM country_films y
                             WHERE y.c_name = cf.c_name AND y.c_rentals = cf.c_rentals)
    )
    SELECT u.name, tf.f_title, COALESCE(tf.c_rentals, 0)::BIGINT
    FROM unnest(p_countries) AS u(name)
    LEFT JOIN top_film tf ON tf.c_name = u.name;
END;
$$;

-- test 1 (valid): the example from the task
SELECT * FROM public.most_popular_films_by_countries(ARRAY['Afghanistan','Brazil','United States']);

-- test 2 (edge): unknown country -> exception
DO $$
BEGIN
    PERFORM * FROM public.most_popular_films_by_countries(ARRAY['Atlantis']);
    RAISE NOTICE 'test 2 FAILED: no error';
EXCEPTION WHEN raise_exception THEN
    RAISE NOTICE 'test 2 ok: %', SQLERRM;
END $$;


-- =====================================================================
-- TASK 4. Films in stock by partial title
-- =====================================================================
-- ILIKE with the user's pattern: % = any chars, _ = one char.
-- ILIKE is case-insensitive, which the example needs ("Lovely Film" has "Love").
-- A leading % can't use a btree index; on a big table use pg_trgm + GIN.
-- In stock = no rental of that copy with return_date NULL.
-- One row per film, numbered from 1. No match / nothing in stock: one row with a message.
-- NULL or blank pattern: exception.

CREATE OR REPLACE FUNCTION public.films_in_stock_by_title(p_pattern TEXT)
RETURNS TABLE (row_num BIGINT, film_title TEXT, copies_in_stock BIGINT)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_pattern IS NULL OR btrim(p_pattern) = '' THEN
        RAISE EXCEPTION 'p_pattern must be a non-empty LIKE pattern, e.g. the word love with wildcards around it';
    END IF;

    RETURN QUERY
    WITH matched AS (
        SELECT f.film_id, f.title FROM public.film f WHERE f.title ILIKE p_pattern
    ),
    stock AS (
        SELECT i.film_id, COUNT(*) AS copies
        FROM public.inventory i
        WHERE i.film_id IN (SELECT m.film_id FROM matched m)
          AND NOT EXISTS (SELECT 1 FROM public.rental r
                          WHERE r.inventory_id = i.inventory_id AND r.return_date IS NULL)
        GROUP BY i.film_id
    )
    SELECT ROW_NUMBER() OVER (ORDER BY m.title), m.title::TEXT, s.copies::BIGINT
    FROM matched m
    JOIN stock s ON s.film_id = m.film_id
    ORDER BY m.title;

    IF NOT FOUND THEN
        RETURN QUERY SELECT 1::BIGINT,
                            ('No films in stock match ' || p_pattern)::TEXT,
                            0::BIGINT;
    END IF;
END;
$$;

-- test 1 (valid): several matches, row_num 1..N
SELECT * FROM public.films_in_stock_by_title('%love%');

-- test 2 (edge): no match -> one message row
SELECT * FROM public.films_in_stock_by_title('%zzqxw%');


-- =====================================================================
-- TASK 5. new_movie(title, year = current year, language = Klingon)
-- =====================================================================
-- id: the column default (the sequence) gives it, so two calls never get the same one.
-- RETURNING gives the id back.
-- Duplicate: checked case-insensitively, after an advisory lock on the title
-- (so two calls can't both pass the check). Exception, nothing inserted.
-- Language: looked up by name; not found -> exception, id taken from the table.
-- Insert is one statement, so a failure leaves nothing behind.
-- rate 4.99, duration 3 days, replacement 19.99 are fixed.

CREATE OR REPLACE FUNCTION public.new_movie(
    p_title        TEXT,
    p_release_year INTEGER DEFAULT EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER,
    p_language     TEXT    DEFAULT 'Klingon'
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_language_id INTEGER;
    v_film_id     INTEGER;
BEGIN
    IF p_title IS NULL OR btrim(p_title) = '' THEN
        RAISE EXCEPTION 'Movie title must not be empty';
    END IF;

    IF p_release_year IS NULL OR p_release_year NOT BETWEEN 1888 AND 2100 THEN
        RAISE EXCEPTION 'Release year % is outside 1888-2100', p_release_year;
    END IF;

    SELECT l.language_id INTO v_language_id
    FROM public.language l
    WHERE l.name = p_language;

    IF v_language_id IS NULL THEN
        RAISE EXCEPTION 'Language % does not exist in the language table', p_language;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext(lower(btrim(p_title))));

    IF EXISTS (SELECT 1 FROM public.film f WHERE lower(f.title) = lower(btrim(p_title))) THEN
        RAISE EXCEPTION 'Movie "%" already exists', p_title;
    END IF;

    INSERT INTO public.film (title, release_year, language_id,
                             rental_rate, rental_duration, replacement_cost, last_update)
    VALUES (btrim(p_title), p_release_year, v_language_id, 4.99, 3, 19.99, now())
    RETURNING film_id INTO v_film_id;

    RETURN v_film_id;
END;
$$;

-- test 1 (valid): defaults are used (year = current, language = Klingon)
DO $$
DECLARE v_id INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.film WHERE title = 'Klingon Day Test') THEN
        v_id := public.new_movie('Klingon Day Test');
        RAISE NOTICE 'test 1 ok, film_id %', v_id;
    ELSE
        RAISE NOTICE 'test 1 skipped: already exists';
    END IF;
END $$;

-- test 2 (edge): duplicate title and unknown language -> exceptions
DO $$
BEGIN
    PERFORM public.new_movie('klingon day test');
    RAISE NOTICE 'test 2a FAILED: duplicate accepted';
EXCEPTION WHEN raise_exception THEN
    RAISE NOTICE 'test 2a ok: %', SQLERRM;
END $$;

DO $$
BEGIN
    PERFORM public.new_movie('Unknown Language Test', 2020, 'Atlantean');
    RAISE NOTICE 'test 2b FAILED: unknown language accepted';
EXCEPTION WHEN raise_exception THEN
    RAISE NOTICE 'test 2b ok: %', SQLERRM;
END $$;


-- =====================================================================
-- TASK 6. Fixes
-- =====================================================================

-- ---- rewards_report ----
-- Old version: window = CURRENT_DATE - 3 months. Today that is August 2026,
-- data is in 2017, so 0 rows. Also 3 months back is not "last month".
-- New version: window = previous calendar month of p_reference_date (default today).
-- No temp table, no EXECUTE, no SECURITY DEFINER.
DROP FUNCTION IF EXISTS public.rewards_report(INTEGER, NUMERIC);

CREATE OR REPLACE FUNCTION public.rewards_report(
    min_monthly_purchases       INTEGER,
    min_dollar_amount_purchased NUMERIC,
    p_reference_date            DATE DEFAULT CURRENT_DATE
)
RETURNS SETOF public.customer
LANGUAGE plpgsql
AS $$
DECLARE
    v_period_start TIMESTAMP;
    v_period_end   TIMESTAMP;
BEGIN
    IF min_monthly_purchases IS NULL OR min_monthly_purchases <= 0 THEN
        RAISE EXCEPTION 'min_monthly_purchases must be greater than 0';
    END IF;
    IF min_dollar_amount_purchased IS NULL OR min_dollar_amount_purchased <= 0 THEN
        RAISE EXCEPTION 'min_dollar_amount_purchased must be greater than 0';
    END IF;

    v_period_end   := date_trunc('month', p_reference_date::TIMESTAMP);
    v_period_start := v_period_end - INTERVAL '1 month';

    RETURN QUERY
    SELECT c.*
    FROM public.customer c
    WHERE c.customer_id IN (
        SELECT p.customer_id
        FROM public.payment p
        WHERE p.payment_date >= v_period_start
          AND p.payment_date <  v_period_end
        GROUP BY p.customer_id
        HAVING SUM(p.amount) > min_dollar_amount_purchased
           AND COUNT(*) > min_monthly_purchases
    );
END;
$$;

-- test 1 (valid): May 2017 window (use the 2017 dump; in the 2007 dump use DATE '2007-06-15')
SELECT COUNT(*) AS rewarded_may_2017 FROM public.rewards_report(2, 50, DATE '2017-06-15');

-- test 2 (edge): zero threshold -> exception
DO $$
BEGIN
    PERFORM * FROM public.rewards_report(0, 50);
    RAISE NOTICE 'test 2 FAILED';
EXCEPTION WHEN raise_exception THEN
    RAISE NOTICE 'test 2 ok: %', SQLERRM;
END $$;


-- ---- get_customer_balance ----
-- Old version: IF() does not exist in PostgreSQL (MySQL syntax), so it always failed.
-- Rules from the old comments:
--   1) rental fees            2) $1 per overdue day (also for rentals not returned yet)
--   3) replacement cost if overdue > 2 * rental_duration
--   4) minus payments up to the date
-- A rental ends at return_date, or at the effective date if it is still out.
-- Overdue days are whole days past rental_date + rental_duration.
-- Replacement rule read as "more than 2x duration" (my reading of the comment).

CREATE OR REPLACE FUNCTION public.get_customer_balance(
    p_customer_id    INTEGER,
    p_effective_date TIMESTAMP
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_rentfees    NUMERIC(10,2);
    v_overfees    NUMERIC(10,2);
    v_replacement NUMERIC(10,2);
    v_payments    NUMERIC(10,2);
BEGIN
    IF p_customer_id IS NULL OR p_effective_date IS NULL THEN
        RAISE EXCEPTION 'customer id and effective date are required';
    END IF;

    WITH rb AS (
        SELECT f.rental_rate, f.rental_duration, f.replacement_cost,
               r.rental_date,
               LEAST(COALESCE(r.return_date, p_effective_date), p_effective_date) AS end_date
        FROM public.rental r
        JOIN public.inventory i ON i.inventory_id = r.inventory_id
        JOIN public.film f      ON f.film_id = i.film_id
        WHERE r.customer_id = p_customer_id
          AND r.rental_date <= p_effective_date
    ),
    od AS (
        SELECT rb.*,
               GREATEST(0, FLOOR(EXTRACT(EPOCH FROM
                   (end_date - rental_date - rental_duration * INTERVAL '1 day')) / 86400)) AS days_late
        FROM rb
    )
    SELECT COALESCE(SUM(rental_rate), 0),
           COALESCE(SUM(days_late), 0),
           COALESCE(SUM(CASE WHEN days_late > 2 * rental_duration THEN replacement_cost ELSE 0 END), 0)
    INTO v_rentfees, v_overfees, v_replacement
    FROM od;

    SELECT COALESCE(SUM(p.amount), 0) INTO v_payments
    FROM public.payment p
    WHERE p.customer_id = p_customer_id
      AND p.payment_date <= p_effective_date;

    RETURN v_rentfees + v_overfees + v_replacement - v_payments;
END;
$$;

-- test 1 (valid): customer 1 on a date with data
SELECT public.get_customer_balance(1, TIMESTAMP '2017-06-01 00:00:00') AS balance_customer_1;

-- test 2 (edge): date before any activity -> 0
SELECT public.get_customer_balance(1, TIMESTAMP '2000-01-01 00:00:00') AS balance_before_activity;

-- test 3 (invalid): NULL customer -> exception
DO $$
BEGIN
    PERFORM public.get_customer_balance(NULL, now()::TIMESTAMP);
    RAISE NOTICE 'test 3 FAILED';
EXCEPTION WHEN raise_exception THEN
    RAISE NOTICE 'test 3 ok: %', SQLERRM;
END $$;


-- =====================================================================
