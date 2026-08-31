-- CTE selects the first session for each account to avoid duplicating
-- accounts/messages when one account has multiple sessions
WITH AccountFirstSession AS (
    SELECT
        acs.account_id,
        se.date AS first_session_date,
        sp.country AS first_session_country,
        ROW_NUMBER() OVER (PARTITION BY acs.account_id ORDER BY se.date, se.ga_session_id) as rn
    FROM
        `DA.account_session` AS acs
    INNER JOIN
        `DA.session` AS se ON acs.ga_session_id = se.ga_session_id
    INNER JOIN `DA.session_params` AS sp ON se.ga_session_id = sp.ga_session_id
),
  email_and_account_data AS (
    SELECT
      afs.first_session_date                                      AS date,
      afs.first_session_country                                   AS country,
      ac.send_interval                                            AS send_interval,
      ac.is_verified                                              AS is_verified,
      ac.is_unsubscribed                                          AS is_unsubscribed,
      COUNT(DISTINCT ac.id)                                       AS account_cnt,
      0                                                           AS sent_msg,
      0                                                           AS open_msg,
      0                                                           AS visit_msg
    -- Base event: account; date and country come from the first session
    FROM `DA.account` AS ac
    INNER JOIN AccountFirstSession AS afs ON ac.id = afs.account_id
    WHERE afs.rn = 1 -- filter: only the first session per account, eliminates duplicates
    GROUP BY 1, 2, 3, 4, 5

    UNION ALL

  SELECT
    -- Send date calculated as an offset (sent_date) from the account's first session date
    DATE_ADD(afs.first_session_date, INTERVAL es.sent_date DAY)  AS date,
    afs.first_session_country                                     AS country,
    ac.send_interval,
    ac.is_verified,
    ac.is_unsubscribed,
    0                                                             AS account_cnt,
    COUNT(DISTINCT es.id_message)                                 AS sent_msg,
    COUNT(DISTINCT eo.id_message)                                 AS open_msg,
    COUNT(DISTINCT ev.id_message)                                 AS visit_msg
  -- Base event: email_sent
  FROM `DA.email_sent` AS es
  LEFT JOIN `DA.account` AS ac ON es.id_account = ac.id
  -- Joining only the first session per account to avoid row multiplication
  LEFT JOIN AccountFirstSession AS afs ON ac.id = afs.account_id AND afs.rn = 1
  LEFT JOIN `DA.email_open` AS eo ON es.id_message = eo.id_message
  -- email_visit joined directly with email_sent via id_message
  LEFT JOIN `DA.email_visit` AS ev ON es.id_message = ev.id_message
  GROUP BY 1, 2, 3, 4, 5
  ),
  aggregated_data AS (
    -- Aggregated data after UNION ALL, used for total account and email counts
    SELECT
      date,
      country,
      send_interval,
      is_verified,
      is_unsubscribed,
      SUM(account_cnt) AS account_cnt,
      SUM(sent_msg)    AS sent_msg,
      SUM(open_msg)    AS open_msg,
      SUM(visit_msg)   AS visit_msg
    FROM email_and_account_data
    GROUP BY 1, 2, 3, 4, 5
  ),
  account_data AS (
    -- Total accounts per country with ranking
    SELECT
      country,
      SUM(account_cnt)                                            AS total_country_account_cnt,
      DENSE_RANK() OVER (ORDER BY SUM(account_cnt) DESC)         AS rank_total_country_account_cnt
    FROM aggregated_data
    GROUP BY country
  ),
  email_data AS (
    -- Total sent messages per country with ranking
    SELECT
      country,
      SUM(sent_msg)                                               AS total_country_sent_cnt,
      DENSE_RANK() OVER (ORDER BY SUM(sent_msg) DESC)            AS rank_total_country_sent_cnt
    FROM aggregated_data
    GROUP BY country
  )
SELECT
  date,
  e.country,
  e.send_interval,
  CASE WHEN e.is_verified = 1 THEN 'verified' ELSE 'not verified' END       AS is_verified,
  CASE WHEN e.is_unsubscribed = 1 THEN 'unsubscribed' ELSE 'active' END     AS is_unsubscribed,
  e.account_cnt,
  e.sent_msg,
  e.open_msg,
  e.visit_msg,
  ad.total_country_account_cnt,
  em.total_country_sent_cnt,
  ad.rank_total_country_account_cnt,
  em.rank_total_country_sent_cnt
FROM aggregated_data AS e
JOIN account_data AS ad ON e.country = ad.country
JOIN email_data AS em ON e.country = em.country
WHERE
  ad.rank_total_country_account_cnt <= 10
  OR em.rank_total_country_sent_cnt <= 10;
