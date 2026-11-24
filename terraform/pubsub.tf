resource "google_pubsub_topic" "telemetry" {
  name = "smart-meter-events"

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [google_project_service_identity.pubsub]
}

resource "google_pubsub_subscription" "bigquery" {
  name  = "sub-meter-bigquery"
  topic = google_pubsub_topic.telemetry.id

  message_retention_duration = "86400s"

  bigquery_config {
    table          = "${var.project_id}.${google_bigquery_dataset.bronze.dataset_id}.${google_bigquery_table.streaming_raw_events.table_id}"
    write_metadata = true
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letter.id
    max_delivery_attempts = 5
  }

  depends_on = [
    google_bigquery_table_iam_member.pubsub_writer,
    google_pubsub_topic_iam_member.dead_letter_publisher,
    google_pubsub_subscription.dead_letter_reader,
  ]

  lifecycle {
    create_before_destroy = true
  }
}

output "telemetry_topic" {
  value = google_pubsub_topic.telemetry.name
}
