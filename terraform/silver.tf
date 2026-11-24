resource "google_bigquery_dataset" "silver" {
  dataset_id  = "silver_smartgrid"
  location    = google_bigquery_dataset.bronze.location
  description = "Données SmartGrid Pulse nettoyées et structurées."
}

resource "google_bigquery_table" "telemetry_clean" {
  dataset_id          = google_bigquery_dataset.silver.dataset_id
  table_id            = "telemetry_clean"
  description         = "Vue typée et dédoublonnée des relevés IoT valides des sept derniers jours."
  deletion_protection = true

  view {
    use_legacy_sql = false
    query          = <<-SQL
      WITH decoded AS (
        SELECT
          message_id,
          publish_time,
          SAFE.PARSE_JSON(SAFE_CAST(data AS STRING)) AS payload
        FROM `${var.project_id}.${google_bigquery_table.streaming_raw_events.dataset_id}.${google_bigquery_table.streaming_raw_events.table_id}`
        WHERE publish_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
      ),
      typed AS (
        SELECT
          NULLIF(TRIM(JSON_VALUE(payload, '$.event_id')), '') AS event_id,
          NULLIF(TRIM(JSON_VALUE(payload, '$.batch_id')), '') AS batch_id,
          NULLIF(TRIM(JSON_VALUE(payload, '$.device_id')), '') AS device_id,
          SAFE_CAST(JSON_VALUE(payload, '$.timestamp_utc') AS TIMESTAMP) AS event_time,
          SAFE_CAST(JSON_VALUE(payload, '$.metrics.active_power_mw') AS FLOAT64) AS active_power_mw,
          SAFE_CAST(JSON_VALUE(payload, '$.metrics.reactive_power_mvar') AS FLOAT64) AS reactive_power_mvar,
          SAFE_CAST(JSON_VALUE(payload, '$.metrics.voltage_kv') AS FLOAT64) AS voltage_kv,
          SAFE_CAST(JSON_VALUE(payload, '$.metrics.frequency_hz') AS FLOAT64) AS frequency_hz,
          SAFE_CAST(JSON_VALUE(payload, '$.metrics.transformer_temp_c') AS FLOAT64) AS transformer_temp_c,
          NULLIF(TRIM(JSON_VALUE(payload, '$.grid_status')), '') AS grid_status,
          SAFE_CAST(JSON_VALUE(payload, '$.is_alert') AS BOOL) AS is_alert,
          message_id,
          publish_time
        FROM decoded
      )
      SELECT *
      FROM typed
      WHERE event_id IS NOT NULL
        AND device_id IS NOT NULL
        AND event_time IS NOT NULL
        AND NOT IS_INF(active_power_mw) AND NOT IS_NAN(active_power_mw)
        AND NOT IS_INF(reactive_power_mvar) AND NOT IS_NAN(reactive_power_mvar)
        AND voltage_kv BETWEEN 360 AND 440
        AND frequency_hz BETWEEN 49 AND 51
        AND NOT IS_INF(transformer_temp_c) AND NOT IS_NAN(transformer_temp_c)
        AND grid_status IS NOT NULL
        AND is_alert IS NOT NULL
      QUALIFY ROW_NUMBER() OVER (
        PARTITION BY event_id ORDER BY publish_time DESC, message_id DESC
      ) = 1
    SQL
  }
}
