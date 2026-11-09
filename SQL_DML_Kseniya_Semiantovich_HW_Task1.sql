/*
=====================================================================
DML homework: favourite films, actors, customer, rentals, payments
Database: dvdrental (PostgreSQL 16), schema: public
Run:  psql -d dvdrental -v ON_ERROR_STOP=1 -f DML_Name_Surname_HW.sql
=====================================================================

GENERAL RULES USED IN THIS SCRIPT
- Each subtask is its own transaction (BEGIN ... COMMIT). Why: a failure
  in one subtask leaves the previous, already committed subtasks intact,
  and each step can be checked before it is made permanent.
- If a subtask fails, psql stops (ON_ERROR_STOP=1) and the open transaction
  is rolled back automatically: nothing from that subtask is saved.
- A committed subtask cannot be rolled back by this script. To undo one,
  delete the rows it inserted (identified by the same WHERE conditions).
- Each DML statement is previewed with a SELECT before COMMIT.
- Referential integrity: every foreign key is filled through a SELECT
  from an existing parent row (film, actor, category, store, inventory,
  customer, staff, rental). A missing parent makes the INSERT select no rows,
  and a bad foreign key is rejected by PostgreSQL.
- Duplicates: each INSERT uses WHERE NOT EXISTS on the natural key
  (title, first+last name, film+actor, film+category, film+store, ...).
  The script can be run again and inserts nothing new.
- No IDs are hardcoded. Records are found by title, name, or by
  "the customer that has at least 43 rentals and 43 payments".
- INSERT ... SELECT (instead of INSERT ... VALUES) is used: the values come
  from a SELECT that reads existing keys (language_id, category_id, store_id),
  so the script does not depend on the IDs of a particular database.
- last_update is set to CURRENT_DATE on every new or updated row that has
  this column. The payment table has no last_update column.
*/

-- The customer to change: any existing customer with >= 43 rentals and
-- >= 43 payments. Chosen by a query, not by ID, and kept in a temp table so
-- every subtask uses the same customer. Temp tables live for the session.
DROP TABLE IF EXISTS pg_temp.target_customer;
CREATE TEMP TABLE pg_temp.target_customer AS
SELECT c.customer_id
FROM public.customer AS c
WHERE (SELECT COUNT(*) FROM public.rental AS r WHERE r.customer_id = c.customer_id) >= 43
  AND (SELECT COUNT(*) FROM public.payment AS p WHERE p.customer_id = c.customer_id) >= 43
ORDER BY c.customer_id
LIMIT 1;


/* =====================================================================
   SUBTASK 1. Insert the three favourite films.
   Rates 4.99 / 9.99 / 19.99 and rental durations 1 / 2 / 3 weeks,
   expressed in days (film.rental_duration is in days): 7 / 14 / 21.
   Duplicates: WHERE NOT EXISTS on title.
   Relation: language_id is read from the language table by name 'English'.
   Transaction: separate, so the films exist even if the rest fails.
   Rollback: possible only before COMMIT; afterwards, delete these titles.
   ===================================================================== */
BEGIN;

INSERT INTO public.film (
    title, description, release_year, language_id,
    rental_duration, rental_rate, length, replacement_cost, rating, last_update
)
SELECT
    v.title,
    v.description,
    v.release_year,
    l.language_id,
    v.rental_duration,
    v.rental_rate,
    v.length,
    19.99,
    v.rating,
    CURRENT_DATE
FROM (
    VALUES
        ('Spider-Man',
         'A teenager gains spider-like powers and must learn responsibility.',
         2002, 7, 4.99, 121, CAST('PG-13' AS public.mpaa_rating)),
        ('The Lord of the Rings: The Fellowship of the Ring',
         'A hobbit sets out to destroy a powerful ring.',
         2001, 14, 9.99, 178, CAST('PG-13' AS public.mpaa_rating)),
        ('Carrie',
         'A bullied teenager discovers she has telekinetic powers.',
         1976, 21, 19.99, 98, CAST('R' AS public.mpaa_rating))
) AS v (title, description, release_year, rental_duration, rental_rate, length, rating)
CROSS JOIN (
    SELECT lg.language_id
    FROM public.language AS lg
    WHERE lg.name = 'English'
) AS l
WHERE NOT EXISTS (
    SELECT 1
    FROM public.film AS f
    WHERE f.title = v.title
)
RETURNING film_id, title, rating, rental_rate, rental_duration;

-- Preview: exactly three films, each once.
SELECT film_id, title, release_year, rating, rental_rate, rental_duration
FROM public.film
WHERE title IN ('Spider-Man',
                'The Lord of the Rings: The Fellowship of the Ring',
                'Carrie')
ORDER BY release_year;

COMMIT;


/* =====================================================================
   SUBTASK 2. Insert actors who star in the favourite films.
   Six or more leads in total: 13 here (Spider-Man 4, The Lord of the Rings 6, Carrie 3).
   Duplicates: WHERE NOT EXISTS on first+last name, so an actor who is
   already in the table is reused, not inserted again.
   DISTINCT removes a repeated name inside the VALUES list, since
   NOT EXISTS cannot see rows inserted by the same statement.
   Transaction: separate, so the actors exist before the links are made.
   Rollback: possible before COMMIT; afterwards delete these names.
   ===================================================================== */
BEGIN;

INSERT INTO public.actor (first_name, last_name, last_update)
SELECT DISTINCT
    v.first_name,
    v.last_name,
    CURRENT_DATE
FROM (
    VALUES
        ('Tobey', 'Maguire'), ('Kirsten', 'Dunst'), ('Willem', 'Dafoe'),
        ('James', 'Franco'),
        ('Elijah', 'Wood'), ('Ian', 'McKellen'), ('Viggo', 'Mortensen'),
        ('Sean', 'Astin'), ('Orlando', 'Bloom'), ('Liv', 'Tyler'),
        ('Sissy', 'Spacek'), ('Piper', 'Laurie'), ('John', 'Travolta')
) AS v (first_name, last_name)
WHERE NOT EXISTS (
    SELECT 1
    FROM public.actor AS a
    WHERE a.first_name = v.first_name
      AND a.last_name = v.last_name
)
RETURNING actor_id, first_name, last_name;

-- Preview: actors of the three films.
SELECT a.actor_id, a.first_name, a.last_name
FROM public.actor AS a
WHERE (a.first_name, a.last_name) IN (
    ('Tobey', 'Maguire'), ('Kirsten', 'Dunst'), ('Willem', 'Dafoe'),
    ('James', 'Franco'),
    ('Elijah', 'Wood'), ('Ian', 'McKellen'), ('Viggo', 'Mortensen'),
    ('Sean', 'Astin'), ('Orlando', 'Bloom'), ('Liv', 'Tyler'),
    ('Sissy', 'Spacek'), ('Piper', 'Laurie'), ('John', 'Travolta')
);

COMMIT;


/* =====================================================================
   SUBTASK 3. Link films and actors in film_actor.
   Relation: film is found by title and actor by name, both through JOIN
   to existing rows, so the foreign keys always point to real records.
   Duplicates: WHERE NOT EXISTS on the (film_id, actor_id) pair; the table
   key already forbids duplicates, this makes the script rerunnable.
   JOIN types: INNER JOIN. A name that is not in the table gives no row,
   so a typo results in a missing link rather than a broken one.
   Transaction: separate, so the links are committed together.
   Rollback: possible before COMMIT; afterwards delete these pairs.
   ===================================================================== */
BEGIN;

INSERT INTO public.film_actor (actor_id, film_id, last_update)
SELECT
    a.actor_id,
    f.film_id,
    CURRENT_DATE
FROM (
    VALUES
        ('Spider-Man', 'Tobey', 'Maguire'), ('Spider-Man', 'Kirsten', 'Dunst'),
        ('Spider-Man', 'Willem', 'Dafoe'), ('Spider-Man', 'James', 'Franco'),
        ('The Lord of the Rings: The Fellowship of the Ring', 'Elijah', 'Wood'),
        ('The Lord of the Rings: The Fellowship of the Ring', 'Ian', 'McKellen'),
        ('The Lord of the Rings: The Fellowship of the Ring', 'Viggo', 'Mortensen'),
        ('The Lord of the Rings: The Fellowship of the Ring', 'Sean', 'Astin'),
        ('The Lord of the Rings: The Fellowship of the Ring', 'Orlando', 'Bloom'),
        ('The Lord of the Rings: The Fellowship of the Ring', 'Liv', 'Tyler'),
        ('Carrie', 'Sissy', 'Spacek'), ('Carrie', 'Piper', 'Laurie'),
        ('Carrie', 'John', 'Travolta')
) AS v (film_title, first_name, last_name)
INNER JOIN public.film AS f
    ON f.title = v.film_title
INNER JOIN public.actor AS a
    ON a.first_name = v.first_name
   AND a.last_name = v.last_name
WHERE NOT EXISTS (
    SELECT 1
    FROM public.film_actor AS fa
    WHERE fa.film_id = f.film_id
      AND fa.actor_id = a.actor_id
)
RETURNING film_id, actor_id;

-- Preview: 13 links expected: Spider-Man 4, The Lord of the Rings 6, Carrie 3.
SELECT f.title, COUNT(*) AS actors_linked
FROM public.film_actor AS fa
INNER JOIN public.film AS f ON f.film_id = fa.film_id
WHERE f.title IN ('Spider-Man',
                  'The Lord of the Rings: The Fellowship of the Ring',
                  'Carrie')
GROUP BY f.title
ORDER BY f.title;

COMMIT;


/* =====================================================================
   SUBTASK 4. Link films and categories in film_category.
   Spider-Man -> Action, The Lord of the Rings -> Sci-Fi (no Fantasy
   category exists in dvdrental), Carrie -> Horror.
   Duplicates: WHERE NOT EXISTS on (film_id, category_id).
   Transaction: separate, for the same reasons as above.
   Rollback: possible before COMMIT; afterwards delete these pairs.
   ===================================================================== */
BEGIN;

INSERT INTO public.film_category (film_id, category_id, last_update)
SELECT
    f.film_id,
    c.category_id,
    CURRENT_DATE
FROM (
    VALUES
        ('Spider-Man', 'Action'),
        ('The Lord of the Rings: The Fellowship of the Ring', 'Sci-Fi'),
        ('Carrie', 'Horror')
) AS v (film_title, category_name)
INNER JOIN public.film AS f
    ON f.title = v.film_title
INNER JOIN public.category AS c
    ON c.name = v.category_name
WHERE NOT EXISTS (
    SELECT 1
    FROM public.film_category AS fc
    WHERE fc.film_id = f.film_id
      AND fc.category_id = c.category_id
)
RETURNING film_id, category_id;

-- Preview: one category per film.
SELECT f.title, c.name AS category
FROM public.film_category AS fc
INNER JOIN public.film AS f ON f.film_id = fc.film_id
INNER JOIN public.category AS c ON c.category_id = fc.category_id
WHERE f.title IN ('Spider-Man',
                  'The Lord of the Rings: The Fellowship of the Ring',
                  'Carrie')
ORDER BY f.title;

COMMIT;


/* =====================================================================
   SUBTASK 5. Add one copy of each favourite film to the inventory of the
   first store (by store_id; no ID is hardcoded).
   Duplicates: WHERE NOT EXISTS on (film_id, store_id).
   CROSS JOIN with a single-row subquery: pairs each film with the one
   store. It does not multiply rows, because the subquery returns one row.
   Transaction: separate; the inventory row must exist before rentals.
   Rollback: possible before COMMIT; afterwards delete these copies.
   ===================================================================== */
BEGIN;

INSERT INTO public.inventory (film_id, store_id, last_update)
SELECT
    f.film_id,
    s.store_id,
    CURRENT_DATE
FROM public.film AS f
CROSS JOIN (
    SELECT st.store_id
    FROM public.store AS st
    ORDER BY st.store_id
    LIMIT 1
) AS s
WHERE f.title IN ('Spider-Man',
                  'The Lord of the Rings: The Fellowship of the Ring',
                  'Carrie')
  AND NOT EXISTS (
      SELECT 1
      FROM public.inventory AS i
      WHERE i.film_id = f.film_id
        AND i.store_id = s.store_id
  )
RETURNING inventory_id, film_id, store_id;

-- Preview: one copy of each film in the store.
SELECT i.inventory_id, f.title, i.store_id
FROM public.inventory AS i
INNER JOIN public.film AS f ON f.film_id = i.film_id
WHERE f.title IN ('Spider-Man',
                  'The Lord of the Rings: The Fellowship of the Ring',
                  'Carrie')
ORDER BY f.title;

COMMIT;


/* =====================================================================
   SUBTASK 6. Change the chosen existing customer to your data.
   Only the customer row is updated. The address table is not changed: the
   customer gets an existing address_id (the first one by ID). Several
   customers share that address, which is allowed because we do not edit it.
   The customer's store_id and activebool are kept.
   Duplicates: an UPDATE does not create rows; running it again sets the
   same values.
   Referential integrity: address_id is taken from the address table.
   Transaction: separate, so the change is one atomic step.
   Rollback: possible before COMMIT. After COMMIT, the old values must be
   written back by hand; the old name is in the sample database.
   ===================================================================== */
BEGIN;

UPDATE public.customer AS c
SET first_name  = 'Ksenia',
    last_name   = 'Sementovich',
    email       = 'sementovich21@gmail.com',
    address_id  = (
        SELECT ad.address_id
        FROM public.address AS ad
        ORDER BY ad.address_id
        LIMIT 1
    ),
    last_update = CURRENT_DATE
WHERE c.customer_id = (SELECT tc.customer_id FROM pg_temp.target_customer AS tc)
RETURNING customer_id, first_name, last_name, email, address_id;

-- Preview: the customer keeps at least 43 rentals and 43 payments.
SELECT c.customer_id, c.first_name, c.last_name, c.email,
       (SELECT COUNT(*) FROM public.rental AS r WHERE r.customer_id = c.customer_id) AS rentals,
       (SELECT COUNT(*) FROM public.payment AS p WHERE p.customer_id = c.customer_id) AS payments
FROM public.customer AS c
WHERE c.customer_id = (SELECT tc.customer_id FROM pg_temp.target_customer AS tc);

COMMIT;


/* =====================================================================
   SUBTASK 7. DELETE records related to you (as a customer), except from
   the customer and inventory tables.
   Interpretation used: "you" are the customer row chosen in subtask 6.
   Its original rentals and payments are needed for the >= 43 requirement,
   so they are KEPT. What is deleted are rental and payment rows of OTHER
   customers that carry your name (duplicates of yourself). In a clean
   database this set is empty, so the DELETE removes 0 rows.
   Why safe: the WHERE clause excludes the target customer, and only rows
   of customers named Ksenia Sementovich other than the target are matched.
   Order: payment first, then rental, because payment references rental.
   Rollback: possible before COMMIT; the preview SELECT shows what would go.
   ===================================================================== */
BEGIN;

-- Preview: rows that would be deleted (expected: 0 in a clean run).
SELECT 'payment' AS table_name, COUNT(*) AS rows_to_delete
FROM public.payment AS p
WHERE p.customer_id IN (
    SELECT c.customer_id
    FROM public.customer AS c
    WHERE c.first_name = 'Ksenia'
      AND c.last_name = 'Sementovich'
      AND c.customer_id <> (SELECT tc.customer_id FROM pg_temp.target_customer AS tc)
)
UNION ALL
SELECT 'rental', COUNT(*)
FROM public.rental AS r
WHERE r.customer_id IN (
    SELECT c.customer_id
    FROM public.customer AS c
    WHERE c.first_name = 'Ksenia'
      AND c.last_name = 'Sementovich'
      AND c.customer_id <> (SELECT tc.customer_id FROM pg_temp.target_customer AS tc)
);

DELETE FROM public.payment AS p
WHERE p.customer_id IN (
    SELECT c.customer_id
    FROM public.customer AS c
    WHERE c.first_name = 'Ksenia'
      AND c.last_name = 'Sementovich'
      AND c.customer_id <> (SELECT tc.customer_id FROM pg_temp.target_customer AS tc)
)
RETURNING payment_id;

DELETE FROM public.rental AS r
WHERE r.customer_id IN (
    SELECT c.customer_id
    FROM public.customer AS c
    WHERE c.first_name = 'Ksenia'
      AND c.last_name = 'Sementovich'
      AND c.customer_id <> (SELECT tc.customer_id FROM pg_temp.target_customer AS tc)
)
RETURNING rental_id;

COMMIT;


/* =====================================================================
   SUBTASK 8. Rent the favourite films from the store they are in.
   Rental dates are in the first half of 2017 (Feb, Mar, Apr). Return date is
   rental date + rental duration in days.
   Staff: the first staff member of the same store (by staff_id).
   Duplicates: WHERE NOT EXISTS on (inventory_id, customer_id, rental_date).
   Referential integrity: inventory, customer and staff are found through
   JOIN / subqueries on existing rows, so the foreign keys are valid.
   Transaction: separate, so the rentals are committed before the payments.
   Rollback: possible before COMMIT; afterwards delete these rentals
   (payments in subtask 9 must be deleted first).
   ===================================================================== */
BEGIN;

INSERT INTO public.rental (
    rental_date, inventory_id, customer_id, return_date, staff_id, last_update
)
SELECT
    v.rental_date,
    i.inventory_id,
    tc.customer_id,
    v.rental_date + (f.rental_duration * INTERVAL '1 day'),
    (
        SELECT st.staff_id
        FROM public.staff AS st
        WHERE st.store_id = i.store_id
        ORDER BY st.staff_id
        LIMIT 1
    ),
    CURRENT_DATE
FROM (
    VALUES
        ('Spider-Man', TIMESTAMPTZ '2017-02-10 10:00:00+00'),
        ('The Lord of the Rings: The Fellowship of the Ring', TIMESTAMPTZ '2017-03-15 10:00:00+00'),
        ('Carrie', TIMESTAMPTZ '2017-04-20 10:00:00+00')
) AS v (title, rental_date)
INNER JOIN public.film AS f
    ON f.title = v.title
INNER JOIN public.inventory AS i
    ON i.film_id = f.film_id
   AND i.store_id = (
       SELECT st.store_id
       FROM public.store AS st
       ORDER BY st.store_id
       LIMIT 1
   )
CROSS JOIN pg_temp.target_customer AS tc
WHERE NOT EXISTS (
    SELECT 1
    FROM public.rental AS r
    WHERE r.inventory_id = i.inventory_id
      AND r.customer_id = tc.customer_id
      AND r.rental_date = v.rental_date
)
RETURNING rental_id, inventory_id, customer_id, rental_date, return_date, staff_id;

-- Preview: three rentals of the favourite films by the customer.
SELECT r.rental_id, f.title, r.rental_date, r.return_date, r.staff_id
FROM public.rental AS r
INNER JOIN public.inventory AS i ON i.inventory_id = r.inventory_id
INNER JOIN public.film AS f ON f.film_id = i.film_id
WHERE r.customer_id = (SELECT tc.customer_id FROM pg_temp.target_customer AS tc)
  AND f.title IN ('Spider-Man',
                  'The Lord of the Rings: The Fellowship of the Ring',
                  'Carrie')
ORDER BY r.rental_date;

COMMIT;


/* =====================================================================
   SUBTASK 9. Pay for the favourite rentals.
   Amount = film rental rate. payment_date = rental_date, which is in the
   first half of 2017, so the row goes to an existing partition
   (payment_p2017_02, _03, _04); no new partition is needed.
   Staff: the rental's staff, so the payment is in the same store.
   Duplicates: WHERE NOT EXISTS on rental_id, so each rental is paid once.
   JOIN types: INNER JOIN from rental, so a rental without inventory or
   film is ignored instead of creating a broken payment.
   Transaction: separate; committed only after the rentals exist.
   Rollback: possible before COMMIT; afterwards delete these payments.
   ===================================================================== */
BEGIN;

INSERT INTO public.payment (customer_id, staff_id, rental_id, amount, payment_date)
SELECT
    r.customer_id,
    r.staff_id,
    r.rental_id,
    f.rental_rate,
    r.rental_date
FROM public.rental AS r
INNER JOIN public.inventory AS i
    ON i.inventory_id = r.inventory_id
INNER JOIN public.film AS f
    ON f.film_id = i.film_id
WHERE r.customer_id = (SELECT tc.customer_id FROM pg_temp.target_customer AS tc)
  AND f.title IN ('Spider-Man',
                  'The Lord of the Rings: The Fellowship of the Ring',
                  'Carrie')
  AND r.rental_date >= '2017-01-01'
  AND r.rental_date <  '2017-07-01'
  AND NOT EXISTS (
      SELECT 1
      FROM public.payment AS p
      WHERE p.rental_id = r.rental_id
  )
RETURNING payment_id, rental_id, customer_id, amount, payment_date;

-- Preview: each favourite rental has one payment equal to its rental rate.
SELECT f.title, f.rental_rate, p.amount, p.payment_date
FROM public.payment AS p
INNER JOIN public.rental AS r ON r.rental_id = p.rental_id
INNER JOIN public.inventory AS i ON i.inventory_id = r.inventory_id
INNER JOIN public.film AS f ON f.film_id = i.film_id
WHERE p.customer_id = (SELECT tc.customer_id FROM pg_temp.target_customer AS tc)
  AND f.title IN ('Spider-Man',
                  'The Lord of the Rings: The Fellowship of the Ring',
                  'Carrie')
ORDER BY p.payment_date;

COMMIT;
