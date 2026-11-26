-- Paramètres TIMESTAMP : publish_start et publish_end (borne exclue).
-- publish_time est l'heure de livraison et timestamp_utc l'heure historique.
ASSERT @publish_start < @publish_end AS 'Fenêtre de livraison invalide';

CREATE TEMP TABLE replay_window AS
WITH bronze AS (
  SELECT
    publish_time,
    message_id,
    SAFE.PARSE_JSON(SAFE_CONVERT_BYTES_TO_STRING(data)) AS payload
  FROM `smartgrid-pulse.bronze_smartgrid.streaming_raw_events`
  WHERE publish_time >= @publish_start AND publish_time < @publish_end
),
typed AS (
  SELECT
    JSON_VALUE(payload, '$.event_id') AS event_id,
    SAFE_CAST(JSON_VALUE(payload, '$.event_time') AS TIMESTAMP) AS timestamp_utc,
    publish_time,
    message_id,
    LAX_FLOAT64(JSON_QUERY(payload, '$.actual_load_mw')) AS actual_load_mw,
    LAX_FLOAT64(JSON_QUERY(payload, '$.forecast_load_mw')) AS forecast_load_mw,
    LAX_FLOAT64(JSON_QUERY(payload, '$.price_actual_eur_mwh')) AS price_spot_eur_mwh,
    LAX_FLOAT64(JSON_QUERY(payload, '$.generation_solar_mw')) AS generation_solar_mw,
    LAX_FLOAT64(JSON_QUERY(payload, '$.generation_wind_onshore_mw')) AS generation_wind_onshore_mw,
    JSON_QUERY(payload, '$.weather') AS weather
  FROM bronze
  WHERE JSON_VALUE(payload, '$.schema_version') = '1.0'
    AND JSON_VALUE(payload, '$.source') = 'STREAM_REPLAY'
    AND JSON_VALUE(payload, '$.country_code') = 'ES'
)
SELECT * EXCEPT (message_id)
FROM typed
WHERE timestamp_utc >= TIMESTAMP '2018-01-01 00:00:00+00'
  AND timestamp_utc < TIMESTAMP '2019-01-01 00:00:00+00'
  AND timestamp_utc = TIMESTAMP_TRUNC(timestamp_utc, HOUR)
  AND NOT IS_INF(actual_load_mw)
  AND actual_load_mw >= 0
  AND ARRAY_LENGTH(JSON_QUERY_ARRAY(weather)) > 0
  AND event_id = CONCAT('es-2018-', SUBSTR(LOWER(TO_HEX(SHA256(
    CONCAT('ES|STREAM_REPLAY|', FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', timestamp_utc, 'UTC'))
  ))), 1, 24))
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY event_id ORDER BY publish_time, message_id
) = 1;

BEGIN TRANSACTION;

MERGE `smartgrid-pulse.silver_smartgrid.business_replay_clean` AS silver
USING replay_window AS replay
ON silver.timestamp_utc >= TIMESTAMP '2018-01-01 00:00:00+00'
  AND silver.timestamp_utc < TIMESTAMP '2019-01-01 00:00:00+00'
  AND silver.timestamp_utc = replay.timestamp_utc
  AND silver.event_id = replay.event_id
WHEN NOT MATCHED THEN
  INSERT (
    event_id, timestamp_utc, publish_time, actual_load_mw, forecast_load_mw,
    price_spot_eur_mwh, generation_solar_mw, generation_wind_onshore_mw, weather
  )
  VALUES (
    replay.event_id, replay.timestamp_utc, replay.publish_time, replay.actual_load_mw,
    replay.forecast_load_mw, replay.price_spot_eur_mwh, replay.generation_solar_mw,
    replay.generation_wind_onshore_mw, replay.weather
  );

MERGE `smartgrid-pulse.gold_smartgrid.Fact_Energy_Load` AS gold
USING (
  SELECT
    LOWER(TO_HEX(SHA256(CONCAT(
      'ES|', FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', silver.timestamp_utc, 'UTC')
    )))) AS load_key,
    CAST(FORMAT_TIMESTAMP('%Y%m%d', silver.timestamp_utc, 'Europe/Madrid') AS INT64) AS date_key,
    CAST(FORMAT_TIMESTAMP('%H%M', silver.timestamp_utc, 'Europe/Madrid') AS INT64) AS time_key,
    silver.*
  FROM `smartgrid-pulse.silver_smartgrid.business_replay_clean` AS silver
  INNER JOIN replay_window AS replay USING (event_id, timestamp_utc)
  WHERE silver.timestamp_utc >= TIMESTAMP '2018-01-01 00:00:00+00'
    AND silver.timestamp_utc < TIMESTAMP '2019-01-01 00:00:00+00'
) AS clean
ON gold.timestamp_utc >= TIMESTAMP '2018-01-01 00:00:00+00'
  AND gold.timestamp_utc < TIMESTAMP '2019-01-01 00:00:00+00'
  AND gold.timestamp_utc = clean.timestamp_utc
WHEN NOT MATCHED THEN
  INSERT (
    load_key, date_key, time_key, timestamp_utc, actual_load_mw, forecast_load_mw,
    load_delta_mw, price_spot_eur_mwh, generation_solar_mw, generation_wind_onshore_mw
  )
  VALUES (
    clean.load_key, clean.date_key, clean.time_key, clean.timestamp_utc, clean.actual_load_mw,
    clean.forecast_load_mw, clean.actual_load_mw - clean.forecast_load_mw,
    clean.price_spot_eur_mwh, clean.generation_solar_mw, clean.generation_wind_onshore_mw
  );

COMMIT TRANSACTION;
