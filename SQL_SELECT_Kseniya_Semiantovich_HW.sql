/*
=====================================================================
SQL SELECT homework
Database : dvdrental (PostgreSQL 16), schema: public
Each task has three solutions: CTE, subquery, JOIN.
=====================================================================

ASSUMPTIONS AND BUSINESS LOGIC (MY ASSUMPTIONS, to be confirmed with mentors in the course chat)
---------------------------------------------------------------------
1. [my assumption] Task 1.1: "rate" means film.rental_rate; the condition is strictly "> 1".
   "Animation" is matched by category name, not by a hardcoded category_id.
2. [my assumption] Task 1.2: the rental store of a payment is inventory.store_id of the
   rented copy (payment -> rental -> inventory -> store).
   Revenue = SUM(payment.amount). "After March 2017" = payment_date from
   2017-04-01 onward (no upper bound; the data ends on 2017-05-31).
   address = address and address2 joined with ", "; an empty or NULL
   address2 is ignored (NULLIF + CONCAT_WS).
3. [my assumption] Task 1.3: "since 2015" = release_year >= 2015. Top-5 with LIMIT 5;
   ties at the 5th place are ordered by last_name, first_name.
4. [my assumption] Task 1.4: the rows are years that have at least one film in Drama,
   Travel or Documentary. A genre with no films in a given year is shown
   as 0 (COUNT returns 0, not NULL). Films without release_year are excluded.
5. [my assumption] Task 2.1: revenue of a staff member = SUM(amount) of payments they
   processed in 2017 (by payment_date). The store of a staff member is the
   store of the rental linked to their LAST payment in 2017 (by payment_date);
   this follows the rule that a payment is processed in the store where the
   staff member works. If several payments of one staff member share the
   last timestamp, the one with the largest payment_id is used.
   Top 3 by revenue; ties ordered by last/first name.
6. [my assumption] Task 2.2: rental count = number of rental rows per film (via inventory).
   Top 5; ties ordered by title. Expected audience age from the MPA rating:
     G      -> All ages
     PG     -> All ages, parental guidance suggested
     PG-13  -> 13+
     R      -> 17+ (under 17 requires a parent or adult guardian)
     NC-17  -> 18+
7. [my assumption] Task 3, V1: gap = current year - latest release_year of the actor.
   The result depends on the date the query is run.
8. [my assumption] Task 3, V2: gap = difference between consecutive distinct release years
   of the actor's films. Two films released in the same year are one step.
   The output is the longest gap per actor. Actors with fewer than two
   distinct release years have no gap and are not shown.

JOIN NOTES (general)
---------------------------------------------------------------------
- INNER JOIN keeps only rows with a match on both sides. Rows without a
  match (for example, a store with no payments) disappear from the result.
- LEFT JOIN keeps all rows of the left table; unmatched right columns are NULL.
- CROSS JOIN is not used in this homework.
- Schema name "public." is written before every table.
*/


/* =====================================================================
   TASK 1.1
   Conditions: Show all animation movies released between 2017 and 2019
   with rate more than 1, sorted alphabetically.
   ===================================================================== */

-- CTE solution
-- Conditions: Show all animation movies released between 2017 and 2019 with rate more than 1, sorted alphabetically.
WITH animation_films AS (
    SELECT
        f.film_id,
        f.title,
        f.release_year,
        f.rental_rate
    FROM public.film AS f
    -- INNER JOIN: a film without a category row is not Animation, so it is dropped.
    INNER JOIN public.film_category AS fc
        ON fc.film_id = f.film_id
    INNER JOIN public.category AS c
        ON c.category_id = fc.category_id
    WHERE c.name = 'Animation'
)
SELECT
    af.title,
    af.release_year,
    af.rental_rate
FROM animation_films AS af
WHERE af.release_year BETWEEN 2017 AND 2019
  AND af.rental_rate > 1
ORDER BY af.title;

/*
 CTE: readable named step; the same plan as JOIN.
 Subquery: compact IN filter, a little harder to read.
 JOIN: shortest and most direct.
 Production: JOIN.
*/

-- Subquery solution
-- Conditions: Show all animation movies released between 2017 and 2019 with rate more than 1, sorted alphabetically.
SELECT
    f.title,
    f.release_year,
    f.rental_rate
FROM public.film AS f
WHERE f.release_year BETWEEN 2017 AND 2019
  AND f.rental_rate > 1
  AND f.film_id IN (
      SELECT fc.film_id
      FROM public.film_category AS fc
      WHERE fc.category_id = (
          SELECT c.category_id
          FROM public.category AS c
          WHERE c.name = 'Animation'
      )
  )
ORDER BY f.title;

-- JOIN solution
-- Conditions: Show all animation movies released between 2017 and 2019 with rate more than 1, sorted alphabetically.
SELECT
    f.title,
    f.release_year,
    f.rental_rate
FROM public.film AS f
INNER JOIN public.film_category AS fc
    ON fc.film_id = f.film_id
INNER JOIN public.category AS c
    ON c.category_id = fc.category_id
   AND c.name = 'Animation'
WHERE f.release_year BETWEEN 2017 AND 2019
  AND f.rental_rate > 1
ORDER BY f.title;


/* =====================================================================
   TASK 1.2
   Conditions: Calculate the revenue earned by each rental store after
   March 2017 (since April). Include columns: address and address2 as one
   column, and revenue.
   ===================================================================== */

-- CTE solution
-- Conditions: Calculate the revenue earned by each rental store after March 2017 (since April). Columns: address and address2 as one column, and revenue.
WITH store_payments AS (
    SELECT
        i.store_id,
        p.amount
    FROM public.payment AS p
    -- INNER JOIN: a payment without a rental, or a rental without inventory, is ignored.
    INNER JOIN public.rental AS r
        ON r.rental_id = p.rental_id
    INNER JOIN public.inventory AS i
        ON i.inventory_id = r.inventory_id
    WHERE p.payment_date >= '2017-04-01'
),
store_revenue AS (
    SELECT
        sp.store_id,
        SUM(sp.amount) AS revenue
    FROM store_payments AS sp
    GROUP BY sp.store_id
)
SELECT
    CONCAT_WS(', ', a.address, NULLIF(a.address2, '')) AS address,
    sr.revenue
FROM store_revenue AS sr
-- INNER JOIN: a store without revenue after April is not shown in this version.
INNER JOIN public.store AS s
    ON s.store_id = sr.store_id
INNER JOIN public.address AS a
    ON a.address_id = s.address_id
ORDER BY sr.revenue DESC;

/*
 CTE: clear steps; INNER JOIN drops stores without payments.
 Subquery: COALESCE shows 0 for such stores, but the subquery runs once per store.
 JOIN: one GROUP BY, shortest.
 Production: JOIN.
*/

-- Subquery solution
-- Conditions: Calculate the revenue earned by each rental store after March 2017 (since April). Columns: address and address2 as one column, and revenue.
SELECT
    CONCAT_WS(', ', a.address, NULLIF(a.address2, '')) AS address,
    COALESCE(
        (
            SELECT SUM(p.amount)
            FROM public.payment AS p
            INNER JOIN public.rental AS r
                ON r.rental_id = p.rental_id
            INNER JOIN public.inventory AS i
                ON i.inventory_id = r.inventory_id
            WHERE i.store_id = s.store_id
              AND p.payment_date >= '2017-04-01'
        ),
        0
    ) AS revenue
FROM public.store AS s
INNER JOIN public.address AS a
    ON a.address_id = s.address_id
ORDER BY revenue DESC;

-- JOIN solution
-- Conditions: Calculate the revenue earned by each rental store after March 2017 (since April). Columns: address and address2 as one column, and revenue.
SELECT
    CONCAT_WS(', ', a.address, NULLIF(a.address2, '')) AS address,
    SUM(p.amount) AS revenue
FROM public.payment AS p
INNER JOIN public.rental AS r
    ON r.rental_id = p.rental_id
INNER JOIN public.inventory AS i
    ON i.inventory_id = r.inventory_id
INNER JOIN public.store AS s
    ON s.store_id = i.store_id
INNER JOIN public.address AS a
    ON a.address_id = s.address_id
WHERE p.payment_date >= '2017-04-01'
GROUP BY s.store_id, a.address, a.address2
ORDER BY revenue DESC;


/* =====================================================================
   TASK 1.3
   Conditions: Show top-5 actors by number of movies (released since 2015)
   they took part in. Columns: first_name, last_name, number_of_movies,
   sorted by number_of_movies in descending order.
   ===================================================================== */

-- CTE solution
-- Conditions: Show top-5 actors by number of movies (released since 2015). Columns: first_name, last_name, number_of_movies, sorted by number_of_movies descending.
WITH actor_movie_counts AS (
    SELECT
        a.actor_id,
        a.first_name,
        a.last_name,
        COUNT(*) AS number_of_movies
    FROM public.actor AS a
    INNER JOIN public.film_actor AS fa
        ON fa.actor_id = a.actor_id
    INNER JOIN public.film AS f
        ON f.film_id = fa.film_id
    WHERE f.release_year >= 2015
    GROUP BY a.actor_id, a.first_name, a.last_name
)
SELECT
    amc.first_name,
    amc.last_name,
    amc.number_of_movies
FROM actor_movie_counts AS amc
ORDER BY amc.number_of_movies DESC, amc.last_name, amc.first_name
LIMIT 5;

/*
 CTE: named count step, same logic as JOIN.
 Subquery: derived table plus an extra JOIN.
 JOIN: shortest.
 Production: JOIN.
*/

-- Subquery solution
-- Conditions: Show top-5 actors by number of movies (released since 2015). Columns: first_name, last_name, number_of_movies, sorted by number_of_movies descending.
SELECT
    a.first_name,
    a.last_name,
    t.number_of_movies
FROM public.actor AS a
INNER JOIN (
    SELECT
        fa.actor_id,
        COUNT(*) AS number_of_movies
    FROM public.film_actor AS fa
    WHERE fa.film_id IN (
        SELECT f.film_id
        FROM public.film AS f
        WHERE f.release_year >= 2015
    )
    GROUP BY fa.actor_id
) AS t
    ON t.actor_id = a.actor_id
ORDER BY t.number_of_movies DESC, a.last_name, a.first_name
LIMIT 5;

-- JOIN solution
-- Conditions: Show top-5 actors by number of movies (released since 2015). Columns: first_name, last_name, number_of_movies, sorted by number_of_movies descending.
SELECT
    a.first_name,
    a.last_name,
    COUNT(*) AS number_of_movies
FROM public.actor AS a
INNER JOIN public.film_actor AS fa
    ON fa.actor_id = a.actor_id
INNER JOIN public.film AS f
    ON f.film_id = fa.film_id
WHERE f.release_year >= 2015
GROUP BY a.actor_id, a.first_name, a.last_name
ORDER BY number_of_movies DESC, a.last_name, a.first_name
LIMIT 5;


/* =====================================================================
   TASK 1.4
   Conditions: Show number of Drama, Travel, Documentary movies per year.
   Columns: release_year, number_of_drama_movies, number_of_travel_movies,
   number_of_documentary_movies, sorted by release year in descending order.
   NULL values should be handled.
   ===================================================================== */

-- CTE solution
-- Conditions: Show number of Drama, Travel, Documentary movies per year. Columns: release_year, number_of_drama_movies, number_of_travel_movies, number_of_documentary_movies, sorted by release_year descending; handle NULL values.
WITH genre_films AS (
    SELECT
        f.release_year,
        c.name AS genre
    FROM public.film AS f
    INNER JOIN public.film_category AS fc
        ON fc.film_id = f.film_id
    INNER JOIN public.category AS c
        ON c.category_id = fc.category_id
    WHERE c.name IN ('Drama', 'Travel', 'Documentary')
      AND f.release_year IS NOT NULL
)
SELECT
    gf.release_year,
    COUNT(CASE WHEN gf.genre = 'Drama' THEN 1 END)       AS number_of_drama_movies,
    COUNT(CASE WHEN gf.genre = 'Travel' THEN 1 END)      AS number_of_travel_movies,
    COUNT(CASE WHEN gf.genre = 'Documentary' THEN 1 END) AS number_of_documentary_movies
FROM genre_films AS gf
GROUP BY gf.release_year
ORDER BY gf.release_year DESC;

/*
 CTE: named filter, pivot in one SELECT.
 Subquery: one scalar subquery per genre, slower.
 JOIN: one pivot with COUNT(CASE ...); COUNT returns 0, not NULL.
 Production: JOIN with conditional aggregation.
*/

-- Subquery solution
-- Conditions: Show number of Drama, Travel, Documentary movies per year. Columns: release_year, number_of_drama_movies, number_of_travel_movies, number_of_documentary_movies, sorted by release_year descending; handle NULL values.
SELECT
    y.release_year,
    (
        SELECT COUNT(*)
        FROM public.film AS f
        INNER JOIN public.film_category AS fc
            ON fc.film_id = f.film_id
        INNER JOIN public.category AS c
            ON c.category_id = fc.category_id
        WHERE c.name = 'Drama'
          AND f.release_year = y.release_year
    ) AS number_of_drama_movies,
    (
        SELECT COUNT(*)
        FROM public.film AS f
        INNER JOIN public.film_category AS fc
            ON fc.film_id = f.film_id
        INNER JOIN public.category AS c
            ON c.category_id = fc.category_id
        WHERE c.name = 'Travel'
          AND f.release_year = y.release_year
    ) AS number_of_travel_movies,
    (
        SELECT COUNT(*)
        FROM public.film AS f
        INNER JOIN public.film_category AS fc
            ON fc.film_id = f.film_id
        INNER JOIN public.category AS c
            ON c.category_id = fc.category_id
        WHERE c.name = 'Documentary'
          AND f.release_year = y.release_year
    ) AS number_of_documentary_movies
FROM (
    SELECT DISTINCT f.release_year
    FROM public.film AS f
    INNER JOIN public.film_category AS fc
        ON fc.film_id = f.film_id
    INNER JOIN public.category AS c
        ON c.category_id = fc.category_id
    WHERE c.name IN ('Drama', 'Travel', 'Documentary')
      AND f.release_year IS NOT NULL
) AS y
ORDER BY y.release_year DESC;

-- JOIN solution
-- Conditions: Show number of Drama, Travel, Documentary movies per year. Columns: release_year, number_of_drama_movies, number_of_travel_movies, number_of_documentary_movies, sorted by release_year descending; handle NULL values.
SELECT
    f.release_year,
    COUNT(CASE WHEN c.name = 'Drama' THEN 1 END)       AS number_of_drama_movies,
    COUNT(CASE WHEN c.name = 'Travel' THEN 1 END)      AS number_of_travel_movies,
    COUNT(CASE WHEN c.name = 'Documentary' THEN 1 END) AS number_of_documentary_movies
FROM public.film AS f
INNER JOIN public.film_category AS fc
    ON fc.film_id = f.film_id
INNER JOIN public.category AS c
    ON c.category_id = fc.category_id
WHERE c.name IN ('Drama', 'Travel', 'Documentary')
  AND f.release_year IS NOT NULL
GROUP BY f.release_year
ORDER BY f.release_year DESC;


/* =====================================================================
   TASK 2.1
   Conditions: Show which three employees generated the most revenue in 2017.
   Assumptions: staff could work in several stores in a year, indicate the
   last one; if a staff member processed the payment, they work in the same
   store; take into account only payment_date.
   ===================================================================== */

-- CTE solution
-- Conditions: Show which three employees generated the most revenue in 2017. Staff may work in several stores (show the last one); a payment is in the store where the staff works; use payment_date only.
WITH payments_2017 AS (
    SELECT
        p.payment_id,
        p.staff_id,
        p.rental_id,
        p.amount,
        p.payment_date
    FROM public.payment AS p
    WHERE p.payment_date >= '2017-01-01'
      AND p.payment_date <  '2018-01-01'
),
staff_revenue AS (
    SELECT
        p.staff_id,
        SUM(p.amount) AS revenue
    FROM payments_2017 AS p
    GROUP BY p.staff_id
),
staff_last_payment_date AS (
    SELECT
        p.staff_id,
        MAX(p.payment_date) AS last_payment_date
    FROM payments_2017 AS p
    GROUP BY p.staff_id
),
staff_last_payment AS (
    -- one payment per staff member: among payments at the last timestamp, take the largest payment_id
    SELECT
        p.staff_id,
        MAX(p.payment_id) AS last_payment_id
    FROM payments_2017 AS p
    INNER JOIN staff_last_payment_date AS lpd
        ON lpd.staff_id = p.staff_id
       AND lpd.last_payment_date = p.payment_date
    GROUP BY p.staff_id
),
staff_last_store AS (
    SELECT
        p.staff_id,
        i.store_id
    FROM staff_last_payment AS lp
    INNER JOIN payments_2017 AS p
        ON p.payment_id = lp.last_payment_id
    INNER JOIN public.rental AS r
        ON r.rental_id = p.rental_id
    INNER JOIN public.inventory AS i
        ON i.inventory_id = r.inventory_id
)
SELECT
    s.staff_id,
    s.first_name,
    s.last_name,
    sls.store_id,
    sr.revenue
FROM staff_revenue AS sr
INNER JOIN public.staff AS s
    ON s.staff_id = sr.staff_id
INNER JOIN staff_last_store AS sls
    ON sls.staff_id = sr.staff_id
ORDER BY sr.revenue DESC, s.last_name, s.first_name
LIMIT 3;

/*
 CTE: each step can be checked on its own; five CTEs is a lot.
 Subquery: one row per staff member; the "last store" needs ORDER BY ... LIMIT 1.
 JOIN: same logic inline with nested derived tables, harder to read.
 Production: CTE, for readability.
*/

-- Subquery solution
-- Conditions: Show which three employees generated the most revenue in 2017. Staff may work in several stores (show the last one); a payment is in the store where the staff works; use payment_date only.
SELECT
    s.staff_id,
    s.first_name,
    s.last_name,
    (
        SELECT i.store_id
        FROM public.payment AS p
        INNER JOIN public.rental AS r
            ON r.rental_id = p.rental_id
        INNER JOIN public.inventory AS i
            ON i.inventory_id = r.inventory_id
        WHERE p.staff_id = s.staff_id
          AND p.payment_date >= '2017-01-01'
          AND p.payment_date <  '2018-01-01'
        ORDER BY p.payment_date DESC, p.payment_id DESC
        LIMIT 1
    ) AS store_id,
    (
        SELECT SUM(p.amount)
        FROM public.payment AS p
        WHERE p.staff_id = s.staff_id
          AND p.payment_date >= '2017-01-01'
          AND p.payment_date <  '2018-01-01'
    ) AS revenue
FROM public.staff AS s
ORDER BY revenue DESC NULLS LAST, s.last_name, s.first_name
LIMIT 3;

-- JOIN solution
-- Conditions: Show which three employees generated the most revenue in 2017. Staff may work in several stores (show the last one); a payment is in the store where the staff works; use payment_date only.
SELECT
    s.staff_id,
    s.first_name,
    s.last_name,
    lps.store_id,
    sr.revenue
FROM (
    SELECT
        p.staff_id,
        SUM(p.amount) AS revenue
    FROM public.payment AS p
    WHERE p.payment_date >= '2017-01-01'
      AND p.payment_date <  '2018-01-01'
    GROUP BY p.staff_id
) AS sr
INNER JOIN public.staff AS s
    ON s.staff_id = sr.staff_id
INNER JOIN (
    SELECT
        p.staff_id,
        i.store_id
    FROM public.payment AS p
    -- the last payment per staff member: max payment_date, then max payment_id on ties
    INNER JOIN (
        SELECT
            p2.staff_id,
            MAX(p2.payment_id) AS last_payment_id
        FROM public.payment AS p2
        INNER JOIN (
            SELECT
                p3.staff_id,
                MAX(p3.payment_date) AS last_payment_date
            FROM public.payment AS p3
            WHERE p3.payment_date >= '2017-01-01'
              AND p3.payment_date <  '2018-01-01'
            GROUP BY p3.staff_id
        ) AS lpd
            ON lpd.staff_id = p2.staff_id
           AND lpd.last_payment_date = p2.payment_date
        GROUP BY p2.staff_id
    ) AS lp
        ON lp.last_payment_id = p.payment_id
    INNER JOIN public.rental AS r
        ON r.rental_id = p.rental_id
    INNER JOIN public.inventory AS i
        ON i.inventory_id = r.inventory_id
) AS lps
    ON lps.staff_id = sr.staff_id
ORDER BY sr.revenue DESC, s.last_name, s.first_name
LIMIT 3;


/* =====================================================================
   TASK 2.2
   Conditions: Show which 5 movies were rented more than others (number of
   rentals), and the expected age of the audience for these movies, using
   the Motion Picture Association film rating system.
   ===================================================================== */

-- CTE solution
-- Conditions: Show which 5 movies were rented most often (number of rentals) and the expected audience age by MPA rating.
WITH film_rentals AS (
    SELECT
        i.film_id,
        COUNT(*) AS rental_count
    FROM public.rental AS r
    INNER JOIN public.inventory AS i
        ON i.inventory_id = r.inventory_id
    GROUP BY i.film_id
)
SELECT
    f.title,
    f.rating,
    fr.rental_count,
    CASE f.rating
        WHEN 'G'     THEN 'All ages'
        WHEN 'PG'    THEN 'All ages, parental guidance suggested'
        WHEN 'PG-13' THEN '13+'
        WHEN 'R'     THEN '17+ (under 17 requires a parent or adult guardian)'
        WHEN 'NC-17' THEN '18+'
        ELSE 'Unknown'
    END AS expected_audience_age
FROM film_rentals AS fr
INNER JOIN public.film AS f
    ON f.film_id = fr.film_id
ORDER BY fr.rental_count DESC, f.title
LIMIT 5;

/*
 CTE: rental count is reusable.
 Subquery: counts per film; faster on this data.
 JOIN: one GROUP BY, shortest.
 Production: JOIN for a one-off report.
*/

-- Subquery solution
-- Conditions: Show which 5 movies were rented most often (number of rentals) and the expected audience age by MPA rating.
SELECT
    f.title,
    f.rating,
    rc.rental_count,
    CASE f.rating
        WHEN 'G'     THEN 'All ages'
        WHEN 'PG'    THEN 'All ages, parental guidance suggested'
        WHEN 'PG-13' THEN '13+'
        WHEN 'R'     THEN '17+ (under 17 requires a parent or adult guardian)'
        WHEN 'NC-17' THEN '18+'
        ELSE 'Unknown'
    END AS expected_audience_age
FROM public.film AS f
INNER JOIN (
    SELECT
        i.film_id,
        COUNT(*) AS rental_count
    FROM public.rental AS r
    INNER JOIN public.inventory AS i
        ON i.inventory_id = r.inventory_id
    GROUP BY i.film_id
) AS rc
    ON rc.film_id = f.film_id
ORDER BY rc.rental_count DESC, f.title
LIMIT 5;

-- JOIN solution
-- Conditions: Show which 5 movies were rented most often (number of rentals) and the expected audience age by MPA rating.
SELECT
    f.title,
    f.rating,
    COUNT(*) AS rental_count,
    CASE f.rating
        WHEN 'G'     THEN 'All ages'
        WHEN 'PG'    THEN 'All ages, parental guidance suggested'
        WHEN 'PG-13' THEN '13+'
        WHEN 'R'     THEN '17+ (under 17 requires a parent or adult guardian)'
        WHEN 'NC-17' THEN '18+'
        ELSE 'Unknown'
    END AS expected_audience_age
FROM public.rental AS r
INNER JOIN public.inventory AS i
    ON i.inventory_id = r.inventory_id
INNER JOIN public.film AS f
    ON f.film_id = i.film_id
GROUP BY f.film_id, f.title, f.rating
ORDER BY rental_count DESC, f.title
LIMIT 5;


/* =====================================================================
   TASK 3 - V1
   Conditions: Which actors/actresses didn't act for a longer period of time
   than the others? V1: gap between the latest release_year and the current
   year per each actor.
   ===================================================================== */

-- CTE solution
-- Conditions: Task 3, V1: gap between the latest release_year and the current year per actor.
WITH actor_last_release AS (
    SELECT
        fa.actor_id,
        MAX(f.release_year) AS last_release_year
    FROM public.film_actor AS fa
    INNER JOIN public.film AS f
        ON f.film_id = fa.film_id
    WHERE f.release_year IS NOT NULL
    GROUP BY fa.actor_id
)
SELECT
    a.first_name,
    a.last_name,
    alr.last_release_year,
    EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - alr.last_release_year AS years_since_last_release
FROM actor_last_release AS alr
INNER JOIN public.actor AS a
    ON a.actor_id = alr.actor_id
ORDER BY years_since_last_release DESC, a.last_name, a.first_name;

/*
 CTE: named last-year step.
 Subquery: scalar subquery per actor, much slower on this data.
 JOIN: one GROUP BY, fastest.
 Production: JOIN.
*/

-- Subquery solution
-- Conditions: Task 3, V1: gap between the latest release_year and the current year per actor.
SELECT
    t.first_name,
    t.last_name,
    t.last_release_year,
    EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - t.last_release_year AS years_since_last_release
FROM (
    SELECT
        a.first_name,
        a.last_name,
        (
            SELECT MAX(f.release_year)
            FROM public.film_actor AS fa
            INNER JOIN public.film AS f
                ON f.film_id = fa.film_id
            WHERE fa.actor_id = a.actor_id
              AND f.release_year IS NOT NULL
        ) AS last_release_year
    FROM public.actor AS a
) AS t
WHERE t.last_release_year IS NOT NULL
ORDER BY years_since_last_release DESC, t.last_name, t.first_name;

-- JOIN solution
-- Conditions: Task 3, V1: gap between the latest release_year and the current year per actor.
SELECT
    a.first_name,
    a.last_name,
    MAX(f.release_year) AS last_release_year,
    EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER - MAX(f.release_year) AS years_since_last_release
FROM public.actor AS a
INNER JOIN public.film_actor AS fa
    ON fa.actor_id = a.actor_id
INNER JOIN public.film AS f
    ON f.film_id = fa.film_id
WHERE f.release_year IS NOT NULL
GROUP BY a.actor_id, a.first_name, a.last_name
ORDER BY years_since_last_release DESC, a.last_name, a.first_name;


/* =====================================================================
   TASK 3 - V2
   Conditions: V2: gaps between sequential films per each actor. Output the
   longest break per actor.
   ===================================================================== */

-- CTE solution
-- Conditions: Task 3, V2: gaps between sequential films per actor; output the longest gap per actor.
WITH actor_film_years AS (
    SELECT DISTINCT
        fa.actor_id,
        f.release_year
    FROM public.film_actor AS fa
    INNER JOIN public.film AS f
        ON f.film_id = fa.film_id
    WHERE f.release_year IS NOT NULL
),
actor_year_gaps AS (
    SELECT
        afy.actor_id,
        afy.release_year,
        (
            SELECT MIN(nxt.release_year)
            FROM actor_film_years AS nxt
            WHERE nxt.actor_id = afy.actor_id
              AND nxt.release_year > afy.release_year
        ) AS next_release_year
    FROM actor_film_years AS afy
)
SELECT
    a.first_name,
    a.last_name,
    MAX(ayg.next_release_year - ayg.release_year) AS longest_gap_years
FROM actor_year_gaps AS ayg
INNER JOIN public.actor AS a
    ON a.actor_id = ayg.actor_id
WHERE ayg.next_release_year IS NOT NULL
GROUP BY a.actor_id, a.first_name, a.last_name
ORDER BY longest_gap_years DESC, a.last_name, a.first_name;

/*
 CTE: readable, but the per-row scalar subquery is very slow on this data.
 Subquery: same per-row scalar subquery, slowest.
 JOIN: self-join with MIN/GROUP BY, much faster on this data.
 Production: JOIN.
*/

-- Subquery solution
-- Conditions: Task 3, V2: gaps between sequential films per actor; output the longest gap per actor.
SELECT
    a.first_name,
    a.last_name,
    MAX(g.next_release_year - g.release_year) AS longest_gap_years
FROM public.actor AS a
INNER JOIN (
    SELECT DISTINCT
        fa.actor_id,
        f.release_year,
        (
            SELECT MIN(f2.release_year)
            FROM public.film_actor AS fa2
            INNER JOIN public.film AS f2
                ON f2.film_id = fa2.film_id
            WHERE fa2.actor_id = fa.actor_id
              AND f2.release_year > f.release_year
        ) AS next_release_year
    FROM public.film_actor AS fa
    INNER JOIN public.film AS f
        ON f.film_id = fa.film_id
    WHERE f.release_year IS NOT NULL
) AS g
    ON g.actor_id = a.actor_id
WHERE g.next_release_year IS NOT NULL
GROUP BY a.actor_id, a.first_name, a.last_name
ORDER BY longest_gap_years DESC, a.last_name, a.first_name;

-- JOIN solution
-- Conditions: Task 3, V2: gaps between sequential films per actor; output the longest gap per actor.
SELECT
    a.first_name,
    a.last_name,
    MAX(g.gap_years) AS longest_gap_years
FROM public.actor AS a
INNER JOIN (
    SELECT
        fa1.actor_id,
        f1.release_year,
        MIN(f2.release_year) - f1.release_year AS gap_years
    FROM public.film_actor AS fa1
    INNER JOIN public.film AS f1
        ON f1.film_id = fa1.film_id
    INNER JOIN public.film_actor AS fa2
        ON fa2.actor_id = fa1.actor_id
    -- INNER JOIN: the last film of an actor has no later film, so it gives no gap.
    INNER JOIN public.film AS f2
        ON f2.film_id = fa2.film_id
       AND f2.release_year > f1.release_year
    WHERE f1.release_year IS NOT NULL
    GROUP BY fa1.actor_id, f1.release_year
) AS g
    ON g.actor_id = a.actor_id
GROUP BY a.actor_id, a.first_name, a.last_name
ORDER BY longest_gap_years DESC, a.last_name, a.first_name;
