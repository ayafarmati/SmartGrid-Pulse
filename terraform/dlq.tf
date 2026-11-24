resource "google_pubsub_topic" "dead_letter" {
  name = "smart-meter-dlq"

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [google_project_service_identity.pubsub]
}

resource "google_pubsub_subscription" "dead_letter_reader" {
  name  = "sub-meter-dlq"
  topic = google_pubsub_topic.dead_letter.id

  message_retention_duration = "604800s"

  expiration_policy {
    ttl = ""
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_pubsub_topic_iam_member" "dead_letter_publisher" {
  topic  = google_pubsub_topic.dead_letter.name
  role   = "roles/pubsub.publisher"
  member = google_project_service_identity.pubsub.member
}

resource "google_pubsub_subscription_iam_member" "dead_letter_acknowledger" {
  for_each = {
    bigquery = google_pubsub_subscription.bigquery.name
    archive  = google_pubsub_subscription.gcs_archive.name
  }

  subscription = each.value
  role         = "roles/pubsub.subscriber"
  member       = google_project_service_identity.pubsub.member
}
