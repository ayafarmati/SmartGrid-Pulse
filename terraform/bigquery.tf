resource "google_bigquery_dataset" "bronze" {
  dataset_id  = "bronze_smartgrid"
  location    = var.region
  description = "Couche Bronze de la télémétrie SmartGrid Pulse."

  depends_on = [google_project_service.api["bigquery.googleapis.com"]]
}

resource "google_bigquery_table" "streaming_raw_events" {
  dataset_id               = google_bigquery_dataset.bronze.dataset_id
  table_id                 = "streaming_raw_events"
  require_partition_filter = true

  time_partitioning {
    type          = "DAY"
    field         = "publish_time"
    expiration_ms = 604800000 # Sept jours pour les messages de développement.
  }

  schema = jsonencode([
    { name = "data", type = "BYTES", mode = "NULLABLE" },
    { name = "subscription_name", type = "STRING", mode = "NULLABLE" },
    { name = "message_id", type = "STRING", mode = "NULLABLE" },
    { name = "publish_time", type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "attributes", type = "JSON", mode = "NULLABLE" },
  ])
}

resource "google_bigquery_table_iam_member" "pubsub_writer" {
  project    = var.project_id
  dataset_id = google_bigquery_table.streaming_raw_events.dataset_id
  table_id   = google_bigquery_table.streaming_raw_events.table_id
  role       = "roles/bigquery.dataEditor"
  member     = google_project_service_identity.pubsub.member
}

output "bronze_table" {
  value = "${var.project_id}.${google_bigquery_dataset.bronze.dataset_id}.${google_bigquery_table.streaming_raw_events.table_id}"
}
