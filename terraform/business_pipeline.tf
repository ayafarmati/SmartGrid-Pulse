variable "enable_business_pipeline" {
  description = "Active le replay métier 2018 et ses tables décisionnelles. Faux par défaut pour empêcher tout déploiement accidentel."
  type        = bool
  default     = false
}

variable "business_replay_image" {
  description = "Image Artifact Registry du Cloud Run Job de replay. Laisser vide tant que l'image n'est pas construite."
  type        = string
  default     = ""
}

variable "business_replay_input_uri" {
  description = "Fichier NDJSON 2018 préparé par le batch, par exemple gs://bucket/replay-input/2018/events.ndjson."
  type        = string
  default     = ""
}

locals {
  create_business_replay_job = (
    var.enable_business_pipeline &&
    var.business_replay_image != "" &&
    var.business_replay_input_uri != ""
  )

  load_prediction_schema = jsonencode([
    { name = "prediction_key", type = "STRING", mode = "REQUIRED", description = "Clé idempotente cible+horizon+modèle." },
    { name = "prediction_time_utc", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "target_time_utc", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "horizon_hours", type = "INTEGER", mode = "REQUIRED" },
    { name = "source", type = "STRING", mode = "REQUIRED", description = "BATCH_HISTORICAL ou STREAM_REPLAY." },
    { name = "model_id", type = "STRING", mode = "REQUIRED" },
    { name = "model_version", type = "STRING", mode = "REQUIRED" },
    { name = "predicted_load_mw", type = "FLOAT", mode = "REQUIRED" },
    { name = "actual_load_mw", type = "FLOAT", mode = "NULLABLE" },
    { name = "absolute_error_mw", type = "FLOAT", mode = "NULLABLE" },
    { name = "absolute_percentage_error", type = "FLOAT", mode = "NULLABLE" },
    { name = "created_at", type = "TIMESTAMP", mode = "REQUIRED" },
  ])

  renewable_prediction_schema = jsonencode([
    { name = "prediction_key", type = "STRING", mode = "REQUIRED" },
    { name = "prediction_time_utc", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "target_time_utc", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "horizon_hours", type = "INTEGER", mode = "REQUIRED" },
    { name = "source", type = "STRING", mode = "REQUIRED" },
    { name = "energy_type", type = "STRING", mode = "REQUIRED", description = "SOLAR ou WIND." },
    { name = "model_id", type = "STRING", mode = "REQUIRED" },
    { name = "model_version", type = "STRING", mode = "REQUIRED" },
    { name = "predicted_generation_mw", type = "FLOAT", mode = "REQUIRED" },
    { name = "actual_generation_mw", type = "FLOAT", mode = "NULLABLE" },
    { name = "created_at", type = "TIMESTAMP", mode = "REQUIRED" },
  ])

  price_prediction_schema = jsonencode([
    { name = "prediction_key", type = "STRING", mode = "REQUIRED" },
    { name = "prediction_time_utc", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "target_time_utc", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "horizon_hours", type = "INTEGER", mode = "REQUIRED" },
    { name = "source", type = "STRING", mode = "REQUIRED" },
    { name = "model_id", type = "STRING", mode = "REQUIRED" },
    { name = "model_version", type = "STRING", mode = "REQUIRED" },
    { name = "demand_model_version", type = "STRING", mode = "REQUIRED" },
    { name = "solar_model_version", type = "STRING", mode = "REQUIRED" },
    { name = "wind_model_version", type = "STRING", mode = "REQUIRED" },
    { name = "predicted_price_eur_mwh", type = "FLOAT", mode = "REQUIRED" },
    { name = "actual_price_eur_mwh", type = "FLOAT", mode = "NULLABLE" },
    { name = "created_at", type = "TIMESTAMP", mode = "REQUIRED" },
  ])

  anomaly_schema = jsonencode([
    { name = "anomaly_key", type = "STRING", mode = "REQUIRED" },
    { name = "detected_at", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "target_time_utc", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "anomaly_type", type = "STRING", mode = "REQUIRED" },
    { name = "severity", type = "STRING", mode = "REQUIRED" },
    { name = "observed_value", type = "FLOAT", mode = "REQUIRED" },
    { name = "predicted_value", type = "FLOAT", mode = "REQUIRED" },
    { name = "residual_value", type = "FLOAT", mode = "REQUIRED" },
    { name = "threshold_value", type = "FLOAT", mode = "REQUIRED" },
    { name = "model_id", type = "STRING", mode = "REQUIRED" },
    { name = "model_version", type = "STRING", mode = "REQUIRED" },
    { name = "source", type = "STRING", mode = "REQUIRED" },
    { name = "explanation", type = "STRING", mode = "REQUIRED" },
  ])

  recommendation_schema = jsonencode([
    { name = "decision_key", type = "STRING", mode = "REQUIRED" },
    { name = "decision_time_utc", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "target_time_utc", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "vigilance_level", type = "STRING", mode = "REQUIRED" },
    { name = "residual_demand_mw", type = "FLOAT", mode = "REQUIRED" },
    { name = "solar_coverage_pct", type = "FLOAT", mode = "REQUIRED" },
    { name = "wind_coverage_pct", type = "FLOAT", mode = "REQUIRED" },
    { name = "renewable_coverage_pct", type = "FLOAT", mode = "REQUIRED" },
    { name = "predicted_price_eur_mwh", type = "FLOAT", mode = "REQUIRED" },
    { name = "rule_version", type = "STRING", mode = "REQUIRED" },
    { name = "reason_codes", type = "STRING", mode = "REPEATED" },
    { name = "recommendations", type = "STRING", mode = "REPEATED" },
    { name = "model_versions", type = "JSON", mode = "REQUIRED" },
  ])
}

resource "google_service_account" "business_replay" {
  count        = local.create_business_replay_job ? 1 : 0
  account_id   = "sa-business-replay"
  display_name = "SmartGrid business replay 2018"
}

resource "google_pubsub_topic_iam_member" "business_replay_publisher" {
  count  = local.create_business_replay_job ? 1 : 0
  topic  = google_pubsub_topic.telemetry.name
  role   = "roles/pubsub.publisher"
  member = google_service_account.business_replay[0].member
}

resource "google_storage_bucket_iam_member" "business_replay_objects" {
  count  = local.create_business_replay_job ? 1 : 0
  bucket = google_storage_bucket.bronze.name
  role   = "roles/storage.objectUser"
  member = google_service_account.business_replay[0].member

  condition {
    title      = "business_replay_checkpoint"
    expression = "resource.name == 'projects/_/buckets/${google_storage_bucket.bronze.name}/objects/checkpoints/business-replay-2018.txt'"
  }
}

resource "google_storage_bucket_iam_member" "business_replay_input" {
  count  = local.create_business_replay_job ? 1 : 0
  bucket = google_storage_bucket.bronze.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.business_replay[0].member

  condition {
    title      = "business_replay_input"
    expression = "resource.name == 'projects/_/buckets/${trimprefix(replace(var.business_replay_input_uri, "/replay-input/", "/objects/replay-input/"), "gs://")}'"
  }
}

resource "google_cloud_run_v2_job" "business_replay" {
  count = local.create_business_replay_job ? 1 : 0

  name                = "smartgrid-business-replay-2018"
  location            = var.region
  deletion_protection = true

  lifecycle {
    precondition {
      condition     = startswith(var.business_replay_input_uri, "gs://${google_storage_bucket.bronze.name}/replay-input/2018/")
      error_message = "Déposer l’entrée du job sous replay-input/2018/ dans le bucket Bronze."
    }
  }

  template {
    template {
      service_account = google_service_account.business_replay[0].email
      timeout         = "14400s"

      containers {
        image = var.business_replay_image

        env {
          name  = "INPUT_URI"
          value = var.business_replay_input_uri
        }
        env {
          name  = "GOOGLE_CLOUD_PROJECT"
          value = var.project_id
        }
        env {
          name  = "TOPIC_ID"
          value = google_pubsub_topic.telemetry.name
        }
        env {
          name  = "CHECKPOINT_URI"
          value = "gs://${google_storage_bucket.bronze.name}/checkpoints/business-replay-2018.txt"
        }
        env {
          name  = "INTERVAL_SECONDS"
          value = "1"
        }

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }
      }
    }
  }

  depends_on = [
    google_project_service.simulator_api,
    google_pubsub_topic_iam_member.business_replay_publisher,
    google_storage_bucket_iam_member.business_replay_objects,
    google_storage_bucket_iam_member.business_replay_input,
    google_pubsub_subscription.bigquery,
    google_pubsub_subscription.gcs_archive,
  ]
}

resource "google_bigquery_table" "business_replay_silver" {
  count                    = var.enable_business_pipeline ? 1 : 0
  dataset_id               = google_bigquery_dataset.silver.dataset_id
  table_id                 = "business_replay_clean"
  deletion_protection      = true
  require_partition_filter = true

  schema = jsonencode([
    { name = "event_id", type = "STRING", mode = "REQUIRED" },
    { name = "timestamp_utc", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "publish_time", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "actual_load_mw", type = "FLOAT", mode = "REQUIRED" },
    { name = "forecast_load_mw", type = "FLOAT", mode = "NULLABLE" },
    { name = "price_spot_eur_mwh", type = "FLOAT", mode = "NULLABLE" },
    { name = "generation_solar_mw", type = "FLOAT", mode = "NULLABLE" },
    { name = "generation_wind_onshore_mw", type = "FLOAT", mode = "NULLABLE" },
    { name = "weather", type = "JSON", mode = "REQUIRED" },
  ])

  time_partitioning {
    type  = "DAY"
    field = "timestamp_utc"
  }
}

resource "google_bigquery_table" "fact_load_predictions" {
  count                    = var.enable_business_pipeline ? 1 : 0
  dataset_id               = google_bigquery_dataset.gold.dataset_id
  table_id                 = "Fact_Load_Predictions"
  deletion_protection      = true
  require_partition_filter = true
  clustering               = ["source", "model_id", "horizon_hours"]
  schema                   = local.load_prediction_schema
  time_partitioning {
    type  = "DAY"
    field = "target_time_utc"
  }
}

resource "google_bigquery_table" "fact_renewable_predictions" {
  count                    = var.enable_business_pipeline ? 1 : 0
  dataset_id               = google_bigquery_dataset.gold.dataset_id
  table_id                 = "Fact_Renewable_Predictions"
  deletion_protection      = true
  require_partition_filter = true
  clustering               = ["energy_type", "source", "model_id"]
  schema                   = local.renewable_prediction_schema
  time_partitioning {
    type  = "DAY"
    field = "target_time_utc"
  }
}

resource "google_bigquery_table" "fact_price_predictions" {
  count                    = var.enable_business_pipeline ? 1 : 0
  dataset_id               = google_bigquery_dataset.gold.dataset_id
  table_id                 = "Fact_Price_Predictions"
  deletion_protection      = true
  require_partition_filter = true
  clustering               = ["source", "model_id", "horizon_hours"]
  schema                   = local.price_prediction_schema
  time_partitioning {
    type  = "DAY"
    field = "target_time_utc"
  }
}

resource "google_bigquery_table" "fact_anomalies" {
  count                    = var.enable_business_pipeline ? 1 : 0
  dataset_id               = google_bigquery_dataset.gold.dataset_id
  table_id                 = "Fact_Anomalies"
  deletion_protection      = true
  require_partition_filter = true
  clustering               = ["severity", "anomaly_type", "source"]
  schema                   = local.anomaly_schema
  time_partitioning {
    type  = "DAY"
    field = "target_time_utc"
  }
}

resource "google_bigquery_table" "fact_recommendations" {
  count                    = var.enable_business_pipeline ? 1 : 0
  dataset_id               = google_bigquery_dataset.gold.dataset_id
  table_id                 = "Fact_Recommendations"
  deletion_protection      = true
  require_partition_filter = true
  clustering               = ["vigilance_level", "rule_version"]
  schema                   = local.recommendation_schema
  time_partitioning {
    type  = "DAY"
    field = "target_time_utc"
  }
}
