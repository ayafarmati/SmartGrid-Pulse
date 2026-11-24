resource "google_bigquery_table" "telemetry_latest" {
  dataset_id          = google_bigquery_dataset.gold.dataset_id
  table_id            = "telemetry_latest"
  description         = "Dernier relevé IoT valide disponible par sous-station, pour la supervision."
  deletion_protection = true

  view {
    use_legacy_sql = false
    query          = <<-SQL
      SELECT
        device_id,
        event_time,
        active_power_mw,
        reactive_power_mvar,
        voltage_kv,
        frequency_hz,
        transformer_temp_c,
        grid_status,
        is_alert,
        event_id,
        batch_id,
        message_id,
        publish_time
      FROM `${var.project_id}.${google_bigquery_table.telemetry_clean.dataset_id}.${google_bigquery_table.telemetry_clean.table_id}`
      QUALIFY ROW_NUMBER() OVER (
        PARTITION BY device_id
        ORDER BY event_time DESC, publish_time DESC, message_id DESC, event_id DESC
      ) = 1
    SQL
  }
}
