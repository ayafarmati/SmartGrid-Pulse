DECLARE start_date DATE DEFAULT DATE '2011-11-01';
DECLARE end_date DATE DEFAULT DATE '2014-02-28';

MERGE `smartgrid-pulse.gold_smartgrid.Dim_Date` AS target
USING (
  SELECT
    CAST(FORMAT_DATE('%Y%m%d', calendar_date) AS INT64) AS date_key,
    calendar_date AS full_date,
    EXTRACT(YEAR FROM calendar_date) AS year,
    EXTRACT(QUARTER FROM calendar_date) AS quarter,
    EXTRACT(MONTH FROM calendar_date) AS month,
    EXTRACT(ISOWEEK FROM calendar_date) AS iso_week,
    EXTRACT(DAY FROM calendar_date) AS day_of_month,
    MOD(EXTRACT(DAYOFWEEK FROM calendar_date) + 5, 7) + 1 AS day_of_week,
    EXTRACT(DAYOFWEEK FROM calendar_date) IN (1, 7) AS is_weekend,
    CAST(NULL AS BOOL) AS is_holiday_uk,
    CAST(NULL AS STRING) AS holiday_name
  FROM UNNEST(GENERATE_DATE_ARRAY(start_date, end_date)) AS calendar_date
) AS source
ON target.date_key = source.date_key
WHEN MATCHED THEN UPDATE SET
  full_date = source.full_date,
  year = source.year,
  quarter = source.quarter,
  month = source.month,
  iso_week = source.iso_week,
  day_of_month = source.day_of_month,
  day_of_week = source.day_of_week,
  is_weekend = source.is_weekend
WHEN NOT MATCHED THEN INSERT ROW;

MERGE `smartgrid-pulse.gold_smartgrid.Dim_Time` AS target
USING (
  SELECT
    hour_value * 100 + minute_value AS time_key,
    hour_value * 2 + DIV(minute_value, 30) AS interval_index,
    hour_value AS hour,
    minute_value AS minute,
    FORMAT('%02d:%02d', hour_value, minute_value) AS time_label
  FROM UNNEST(GENERATE_ARRAY(0, 23)) AS hour_value
  CROSS JOIN UNNEST([0, 30]) AS minute_value
) AS source
ON target.time_key = source.time_key
WHEN MATCHED THEN UPDATE SET
  interval_index = source.interval_index,
  hour = source.hour,
  minute = source.minute,
  time_label = source.time_label
WHEN NOT MATCHED THEN INSERT ROW;

MERGE `smartgrid-pulse.gold_smartgrid.Dim_Virtual_Group` AS target
USING (
  SELECT
    FORMAT('LONDON-GROUP-%02d', group_number) AS virtual_group_id,
    FORMAT('Groupe virtuel Londres %02d', group_number) AS group_label,
    group_number,
    'SHA256(meter_id) modulo 5' AS grouping_rule
  FROM UNNEST(GENERATE_ARRAY(1, 5)) AS group_number
) AS source
ON target.virtual_group_id = source.virtual_group_id
WHEN MATCHED THEN UPDATE SET
  group_label = source.group_label,
  group_number = source.group_number,
  grouping_rule = source.grouping_rule
WHEN NOT MATCHED THEN INSERT ROW;
