resource "google_bigquery_dataset" "silver" {
  dataset_id  = "silver_smartgrid"
  location    = google_bigquery_dataset.bronze.location
  description = "Relevés de consommation londoniens nettoyés, typés et dédupliqués."
}

resource "google_bigquery_table" "telemetry_clean" {
  dataset_id          = google_bigquery_dataset.silver.dataset_id
  table_id            = "telemetry_clean"
  description         = "Vue Silver des relevés London Smart Meters rejoués via Pub/Sub."
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
        WHERE publish_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
      ),
      typed AS (
        SELECT
          NULLIF(TRIM(JSON_VALUE(payload, '$.event_id')), '') AS event_id,
          NULLIF(TRIM(JSON_VALUE(payload, '$.meter_id')), '') AS meter_id,
          NULLIF(TRIM(JSON_VALUE(payload, '$.virtual_group_id')), '') AS virtual_group_id,
          SAFE_CAST(JSON_VALUE(payload, '$.event_time') AS TIMESTAMP) AS event_time,
          COALESCE(
            SAFE_CAST(JSON_VALUE(payload, '$.ingestion_time') AS TIMESTAMP),
            publish_time
          ) AS ingestion_time,
          SAFE_CAST(JSON_VALUE(payload, '$.energy_kwh') AS FLOAT64) AS energy_kwh,
          NULLIF(TRIM(JSON_VALUE(payload, '$.source')), '') AS source,
          NULLIF(TRIM(JSON_VALUE(payload, '$.schema_version')), '') AS schema_version,
          message_id,
          publish_time
        FROM decoded
      )
      SELECT
        *,
        TIMESTAMP_DIFF(ingestion_time, event_time, SECOND) AS delivery_lag_seconds,
        'VALID' AS quality_status
      FROM typed
      WHERE event_id IS NOT NULL
        AND meter_id IS NOT NULL
        AND virtual_group_id IS NOT NULL
        AND event_time IS NOT NULL
        AND ingestion_time IS NOT NULL
        AND energy_kwh IS NOT NULL
        AND NOT IS_INF(energy_kwh)
        AND NOT IS_NAN(energy_kwh)
        AND energy_kwh BETWEEN 0 AND 100
        AND source = 'STREAM_REPLAY'
        AND schema_version = '1.0'
      QUALIFY ROW_NUMBER() OVER (
        PARTITION BY event_id ORDER BY publish_time DESC, message_id DESC
      ) = 1
    SQL
  }
}
