resource "google_project_service" "storage" {
  project            = var.project_id
  service            = "storage.googleapis.com"
  disable_on_destroy = false
}

resource "google_storage_bucket" "bronze" {
  name                        = "${var.project_id}-raw-bronze"
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  lifecycle_rule {
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
    condition {
      age                   = 30
      matches_prefix        = ["iot/"]
      matches_storage_class = ["STANDARD"]
    }
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age            = 90
      matches_prefix = ["iot/"]
    }
  }

  depends_on = [google_project_service.storage]
}

resource "google_storage_bucket_iam_member" "pubsub_archive" {
  for_each = toset([
    "roles/storage.objectCreator",
    "roles/storage.legacyBucketReader",
  ])

  bucket = google_storage_bucket.bronze.name
  role   = each.key
  member = google_project_service_identity.pubsub.member
}

resource "google_pubsub_subscription" "gcs_archive" {
  name  = "grid-telemetry-archive-sub"
  topic = google_pubsub_topic.telemetry.id

  ack_deadline_seconds       = 60
  message_retention_duration = "86400s"

  expiration_policy {
    ttl = ""
  }

  cloud_storage_config {
    bucket                   = google_storage_bucket.bronze.name
    filename_prefix          = "iot/"
    filename_datetime_format = "YYYY/MM/DD/hh/mm_ssZ"
    filename_suffix          = ".ndjson"
    max_duration             = "60s"

    text_config {}
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letter.id
    max_delivery_attempts = 5
  }

  depends_on = [
    google_storage_bucket_iam_member.pubsub_archive,
    google_pubsub_topic_iam_member.dead_letter_publisher,
    google_pubsub_subscription.dead_letter_reader,
  ]
}

output "telemetry_archive_uri" {
  value = "gs://${google_storage_bucket.bronze.name}/iot/"
}
