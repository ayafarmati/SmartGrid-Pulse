variable "simulator_image" {
  description = "URI de l’image du service de replay Londres dans Artifact Registry. Sa valeur active Cloud Run."
  type        = string
  default     = null
}

variable "simulator_invoker_member" {
  description = "Identité autorisée à déclencher le replay Londres, par exemple user:adresse@example.com."
  type        = string
  default     = null

  validation {
    condition     = var.simulator_invoker_member == null ? true : can(regex("^(user|serviceAccount):[^@ ]+@[^@ ]+$", var.simulator_invoker_member))
    error_message = "Indique une identité individuelle user: ou serviceAccount: suivie de son adresse."
  }
}

resource "google_project_service" "simulator_api" {
  for_each = toset([
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
    "run.googleapis.com",
  ])

  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "simulator" {
  location      = var.region
  repository_id = "smartgrid-containers"
  format        = "DOCKER"
  description   = "Images Docker des services SmartGrid Pulse."

  depends_on = [google_project_service.simulator_api["artifactregistry.googleapis.com"]]
}

resource "google_service_account" "simulator" {
  account_id   = "sa-meter-replay"
  display_name = "SmartGrid Pulse London Meter Replay"

  depends_on = [google_project_service.simulator_api["iam.googleapis.com"]]
}

resource "google_pubsub_topic_iam_member" "simulator_publisher" {
  topic  = google_pubsub_topic.telemetry.name
  role   = "roles/pubsub.publisher"
  member = google_service_account.simulator.member
}

resource "google_storage_bucket_iam_member" "simulator_replay_reader" {
  bucket = google_storage_bucket.bronze.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.simulator.member
}

resource "google_cloud_run_v2_service" "simulator" {
  count = var.simulator_image == null ? 0 : 1

  name                 = "smartgrid-simulator"
  location             = var.region
  deletion_protection  = true
  ingress              = "INGRESS_TRAFFIC_ALL"
  invoker_iam_disabled = false

  scaling {
    min_instance_count = 0
    max_instance_count = 1
  }

  template {
    service_account                  = google_service_account.simulator.email
    max_instance_request_concurrency = 1
    timeout                          = "30s"

    containers {
      image = var.simulator_image

      ports {
        container_port = 8080
      }

      env {
        name  = "PUBSUB_TOPIC"
        value = google_pubsub_topic.telemetry.id
      }

      env {
        name  = "REPLAY_GCS_PREFIX"
        value = "gs://${google_storage_bucket.bronze.name}/replay/private/2014"
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle = true
      }
    }
  }

  lifecycle {
    precondition {
      condition     = var.simulator_invoker_member != null
      error_message = "Renseigne simulator_invoker_member pour autoriser le déclenchement authentifié du replay."
    }
  }

  depends_on = [
    google_project_service.simulator_api["run.googleapis.com"],
    google_pubsub_topic_iam_member.simulator_publisher,
    google_storage_bucket_iam_member.simulator_replay_reader,
  ]
}

resource "google_cloud_run_v2_service_iam_member" "simulator_invoker" {
  count = var.simulator_image == null || var.simulator_invoker_member == null ? 0 : 1

  location = google_cloud_run_v2_service.simulator[0].location
  name     = google_cloud_run_v2_service.simulator[0].name
  role     = "roles/run.invoker"
  member   = var.simulator_invoker_member
}

output "simulator_repository" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.simulator.repository_id}"
}

output "simulator_url" {
  value = one(google_cloud_run_v2_service.simulator[*].uri)
}

output "replay_source_uri" {
  value = "gs://${google_storage_bucket.bronze.name}/replay/private/2014/"
}
