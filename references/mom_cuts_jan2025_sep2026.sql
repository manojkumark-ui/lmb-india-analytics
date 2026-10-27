-- India confirmed tickets. IST Jan 2025 through Sep 2026.
-- One row per month x segment x cut x channel x user type, with the prior month and MoM change.
-- Segment: LMB = issued 17:00-23:59 IST on the journey date. Non LMB = every other ticket. Overall = LMB + Non LMB.
-- Channels: Android app, iOS app, Others = Mobweb + Desktop.
-- User type: NEW, RETURNING, GUEST, OTHER.
--
-- Distance: Short when the SD is in lis.short_route_sds for the journey year. Else Long.
-- Travel duration: arrival_time minus departure_time, in minutes.
--   <3h, 3-6h, 6-9h, 9-12h, 12h+. Unknown if missing, negative, or 72 hours or more.
-- Week part: Friday, Saturday, Sunday on the IST journey date are Weekend. Monday-Thursday are Weekday.
-- Passenger mix, in seat order: m, f, mm, ff, mf, fm. Groups of 3 or more, or a missing gender, are Other.

WITH
short_routes AS (
  SELECT DISTINCT src_id, dest_id, cohort
  FROM lis.short_route_sds
  WHERE cohort IN ('2025', '2026')
),
raw AS (
  SELECT
    DATE_FORMAT(CAST(AT_TIMEZONE(t.time_of_event, 'Asia/Kolkata') AS TIMESTAMP), '%Y-%m') AS month_key,
    t.tin,
    COALESCE(t.seat_count, 0) AS seat_count,
    COALESCE(t.ticket_fare, 0) AS ticket_fare,
    t.source_location_id,
    t.destination_location_id,
    DATE_FORMAT(CAST(AT_TIMEZONE(t.date_of_journey, 'Asia/Kolkata') AS TIMESTAMP), '%Y') AS doj_year,
    day_of_week(CAST(AT_TIMEZONE(t.date_of_journey, 'Asia/Kolkata') AS DATE)) AS doj_dow,
    DATE_DIFF('minute', t.departure_time, t.arrival_time) AS travel_minutes,
    CARDINALITY(t.travellers_gender) AS pax_n,
    UPPER(TRIM(CAST(element_at(t.travellers_gender, 1) AS VARCHAR))) AS g1,
    UPPER(TRIM(CAST(element_at(t.travellers_gender, 2) AS VARCHAR))) AS g2,
    CASE
      WHEN t.sales_channel = 'RB:MOBILEWEB#droidapp' THEN 'Android'
      WHEN t.sales_channel = 'RB:MOBILEWEB#iosapp' THEN 'iOS'
      ELSE 'Others'
    END AS channel_cut,
    CASE
      WHEN UPPER(COALESCE(t.user_type, '')) = 'NEW' THEN 'NEW'
      WHEN UPPER(COALESCE(t.user_type, '')) IN ('RETURNING', 'EXISTING', 'OLD') THEN 'RETURNING'
      WHEN UPPER(COALESCE(t.user_type, '')) = 'GUEST' THEN 'GUEST'
      ELSE 'OTHER'
    END AS user_type_cut,
    EXTRACT(HOUR FROM AT_TIMEZONE(t.time_of_event, 'Asia/Kolkata')) AS issue_hour,
    DATE_DIFF(
      'day',
      CAST(AT_TIMEZONE(t.time_of_event, 'Asia/Kolkata') AS DATE),
      CAST(AT_TIMEZONE(t.date_of_journey, 'Asia/Kolkata') AS DATE)
    ) AS dbd_days
  FROM transaction.bus_ticket_events t
  WHERE t.country_code = 'IND'
    AND t.event_type = 101
    AND t.event_class = 2
    AND t.tin IS NOT NULL
    AND t.time_of_event >= TIMESTAMP '2024-12-31 18:30:00'
    AND t.time_of_event < TIMESTAMP '2026-09-30 18:30:00'
    AND t.sales_channel IN (
      'RB:MOBILEWEB#droidapp',
      'RB:MOBILEWEB#iosapp',
      'MOBILEWEB',
      'WEBDIRECT'
    )
),
base AS (
  SELECT
    r.month_key,
    r.tin,
    r.seat_count,
    r.ticket_fare,
    r.channel_cut,
    r.user_type_cut,
    CASE
      WHEN r.dbd_days = 0 AND r.issue_hour BETWEEN 17 AND 23 THEN 'LMB'
      ELSE 'Non LMB'
    END AS segment,
    CASE
      WHEN sr.src_id IS NOT NULL THEN 'Short'
      ELSE 'Long'
    END AS distance_band,
    CASE
      WHEN r.travel_minutes IS NULL OR r.travel_minutes < 0 OR r.travel_minutes >= 4320 THEN 'Unknown'
      WHEN r.travel_minutes < 180 THEN '<3h'
      WHEN r.travel_minutes < 360 THEN '3-6h'
      WHEN r.travel_minutes < 540 THEN '6-9h'
      WHEN r.travel_minutes < 720 THEN '9-12h'
      ELSE '12h+'
    END AS travel_duration,
    CASE
      WHEN r.doj_dow IN (5, 6, 7) THEN 'Weekend'
      WHEN r.doj_dow IN (1, 2, 3, 4) THEN 'Weekday'
      ELSE 'Unknown'
    END AS dow_cut,
    CASE
      WHEN r.pax_n = 1 AND r.g1 IN ('MALE', 'M') THEN 'm'
      WHEN r.pax_n = 1 AND r.g1 IN ('FEMALE', 'F') THEN 'f'
      WHEN r.pax_n = 2 AND r.g1 IN ('MALE', 'M') AND r.g2 IN ('MALE', 'M') THEN 'mm'
      WHEN r.pax_n = 2 AND r.g1 IN ('FEMALE', 'F') AND r.g2 IN ('FEMALE', 'F') THEN 'ff'
      WHEN r.pax_n = 2 AND r.g1 IN ('MALE', 'M') AND r.g2 IN ('FEMALE', 'F') THEN 'mf'
      WHEN r.pax_n = 2 AND r.g1 IN ('FEMALE', 'F') AND r.g2 IN ('MALE', 'M') THEN 'fm'
      ELSE 'Other'
    END AS passenger_mix
  FROM raw r
  LEFT JOIN short_routes sr
    ON r.source_location_id = sr.src_id
   AND r.destination_location_id = sr.dest_id
   AND sr.cohort = r.doj_year
),
monthly AS (
  SELECT
    month_key,
    CASE
      WHEN GROUPING(distance_band) = 0 THEN 'Distance'
      WHEN GROUPING(travel_duration) = 0 THEN 'Travel Duration'
      WHEN GROUPING(dow_cut) = 0 THEN 'Week Part'
      WHEN GROUPING(passenger_mix) = 0 THEN 'Passenger Mix'
    END AS cut,
    COALESCE(distance_band, travel_duration, dow_cut, passenger_mix) AS cut_value,
    CASE WHEN GROUPING(segment) = 1 THEN 'Overall' ELSE segment END AS segment,
    channel_cut,
    user_type_cut,
    COUNT(DISTINCT tin) AS orders,
    SUM(seat_count) AS seats,
    SUM(ticket_fare) AS fare
  FROM base
  GROUP BY GROUPING SETS (
    (month_key, segment, channel_cut, user_type_cut, distance_band),
    (month_key, segment, channel_cut, user_type_cut, travel_duration),
    (month_key, segment, channel_cut, user_type_cut, dow_cut),
    (month_key, segment, channel_cut, user_type_cut, passenger_mix),
    (month_key, channel_cut, user_type_cut, distance_band),
    (month_key, channel_cut, user_type_cut, travel_duration),
    (month_key, channel_cut, user_type_cut, dow_cut),
    (month_key, channel_cut, user_type_cut, passenger_mix)
  )
),
mom AS (
  SELECT
    month_key,
    cut,
    cut_value,
    segment,
    channel_cut,
    user_type_cut,
    orders,
    seats,
    fare,
    LAG(orders) OVER (
      PARTITION BY cut, cut_value, segment, channel_cut, user_type_cut
      ORDER BY month_key
    ) AS prev_orders,
    LAG(seats) OVER (
      PARTITION BY cut, cut_value, segment, channel_cut, user_type_cut
      ORDER BY month_key
    ) AS prev_seats,
    LAG(fare) OVER (
      PARTITION BY cut, cut_value, segment, channel_cut, user_type_cut
      ORDER BY month_key
    ) AS prev_fare
  FROM monthly
)
SELECT
  month_key,
  cut,
  cut_value,
  segment,
  channel_cut,
  user_type_cut,
  orders,
  prev_orders,
  CASE
    WHEN prev_orders IS NULL OR prev_orders = 0 THEN NULL
    ELSE 1.0 * (orders - prev_orders) / prev_orders
  END AS orders_mom,
  seats,
  prev_seats,
  CASE
    WHEN prev_seats IS NULL OR prev_seats = 0 THEN NULL
    ELSE 1.0 * (seats - prev_seats) / prev_seats
  END AS seats_mom,
  fare,
  prev_fare,
  CASE
    WHEN prev_fare IS NULL OR prev_fare = 0 THEN NULL
    ELSE 1.0 * (fare - prev_fare) / prev_fare
  END AS fare_mom
FROM mom
ORDER BY cut, cut_value, segment, channel_cut, user_type_cut, month_key
