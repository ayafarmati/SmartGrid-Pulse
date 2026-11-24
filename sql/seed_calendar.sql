-- Paramètres DATE : @start_date et @end_date, bornes incluses.
MERGE `gold_smartgrid.Dim_Date` AS target
USING (
  SELECT
    CAST(FORMAT_DATE('%Y%m%d', full_date) AS INT64) AS date_key,
    full_date,
    EXTRACT(YEAR FROM full_date) AS year,
    EXTRACT(MONTH FROM full_date) AS month,
    ['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août',
     'septembre', 'octobre', 'novembre', 'décembre'][OFFSET(EXTRACT(MONTH FROM full_date) - 1)] AS month_name,
    EXTRACT(DAY FROM full_date) AS day,
    MOD(EXTRACT(DAYOFWEEK FROM full_date) + 5, 7) + 1 AS day_of_week,
    EXTRACT(DAYOFWEEK FROM full_date) IN (1, 7) AS is_weekend,
    CASE
      WHEN EXTRACT(MONTH FROM full_date) IN (12, 1, 2) THEN 'Hiver'
      WHEN EXTRACT(MONTH FROM full_date) IN (3, 4, 5) THEN 'Printemps'
      WHEN EXTRACT(MONTH FROM full_date) IN (6, 7, 8) THEN 'Été'
      ELSE 'Automne'
    END AS season
  FROM UNNEST(GENERATE_DATE_ARRAY(@start_date, @end_date)) AS full_date
) AS calendar
ON target.date_key = calendar.date_key
WHEN NOT MATCHED THEN
  INSERT (date_key, full_date, year, month, month_name, day, day_of_week, is_weekend, season)
  VALUES (calendar.date_key, calendar.full_date, calendar.year, calendar.month, calendar.month_name,
          calendar.day, calendar.day_of_week, calendar.is_weekend, calendar.season);

MERGE `gold_smartgrid.Dim_Time` AS target
USING (
  SELECT
    hour_24 * 100 + minute AS time_key,
    hour_24,
    minute,
    CASE
      WHEN hour_24 < 6 THEN 'Nuit'
      WHEN hour_24 < 12 THEN 'Matin'
      WHEN hour_24 < 18 THEN 'Après-midi'
      ELSE 'Soir'
    END AS period_of_day,
    ((hour_24 >= 8 AND hour_24 < 12) OR (hour_24 >= 18 AND hour_24 < 22)) AS is_peak_hour
  FROM (
    SELECT DIV(minute_of_day, 60) AS hour_24, MOD(minute_of_day, 60) AS minute
    FROM UNNEST(GENERATE_ARRAY(0, 1439)) AS minute_of_day
  )
) AS clock
ON target.time_key = clock.time_key
WHEN NOT MATCHED THEN
  INSERT (time_key, hour_24, minute, period_of_day, is_peak_hour)
  VALUES (clock.time_key, clock.hour_24, clock.minute, clock.period_of_day, clock.is_peak_hour);
