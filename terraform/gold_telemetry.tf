resource "google_bigquery_table" "telemetry_latest" {
  dataset_id          = google_bigquery_dataset.gold.dataset_id
  table_id            = "telemetry_latest"
  description         = "Dernier relevé de consommation valide par compteur londonien."
  deletion_protection = true

  view {
    use_legacy_sql = false
    query          = <<-SQL
      SELECT
        meter_id,
        virtual_group_id,
        event_time,
        ingestion_time,
        energy_kwh,
        delivery_lag_seconds,
        quality_status,
        source,
        schema_version,
        event_id,
        message_id,
        publish_time
      FROM `${var.project_id}.${google_bigquery_table.telemetry_clean.dataset_id}.${google_bigquery_table.telemetry_clean.table_id}`
      QUALIFY ROW_NUMBER() OVER (
        PARTITION BY meter_id
        ORDER BY event_time DESC, publish_time DESC, message_id DESC, event_id DESC
      ) = 1
    SQL
  }
}
