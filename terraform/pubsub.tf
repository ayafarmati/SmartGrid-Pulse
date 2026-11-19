resource "google_pubsub_topic" "telemetry" {
  name = "grid-telemetry-topic"

  depends_on = [google_project_service_identity.pubsub]
}

resource "google_pubsub_subscription" "bigquery" {
  name  = "grid-telemetry-bigquery-sub"
  topic = google_pubsub_topic.telemetry.id

  message_retention_duration = "86400s"

  bigquery_config {
    table          = "${var.project_id}.${google_bigquery_dataset.bronze.dataset_id}.${google_bigquery_table.streaming_raw_events.table_id}"
    write_metadata = true
  }

  depends_on = [google_bigquery_table_iam_member.pubsub_writer]
}

output "telemetry_topic" {
  value = google_pubsub_topic.telemetry.name
}
