# Le nom historique du fichier est conservé pour éviter une migration de dépôt,
# mais toutes les dimensions et tables de faits ci-dessous appartiennent à Gold.

resource "google_bigquery_dataset" "gold" {
  dataset_id  = "gold_smartgrid"
  location    = google_bigquery_dataset.silver.location
  description = "Modèle analytique Londres : dimensions, consommation, météo et prévisions."
}

resource "google_bigquery_table" "dim_date" {
  dataset_id          = google_bigquery_dataset.gold.dataset_id
  table_id            = "Dim_Date"
  description         = "Calendrier britannique utilisé par les charges et prévisions de Londres."
  deletion_protection = true

  schema = jsonencode([
    { name = "date_key", type = "INTEGER", mode = "REQUIRED" },
    { name = "full_date", type = "DATE", mode = "REQUIRED" },
    { name = "year", type = "INTEGER", mode = "REQUIRED" },
    { name = "quarter", type = "INTEGER", mode = "REQUIRED" },
    { name = "month", type = "INTEGER", mode = "REQUIRED" },
    { name = "iso_week", type = "INTEGER", mode = "REQUIRED" },
    { name = "day_of_month", type = "INTEGER", mode = "REQUIRED" },
    { name = "day_of_week", type = "INTEGER", mode = "REQUIRED", description = "1=lundi, 7=dimanche." },
    { name = "is_weekend", type = "BOOLEAN", mode = "REQUIRED" },
    { name = "is_holiday_uk", type = "BOOLEAN", mode = "NULLABLE" },
    { name = "holiday_name", type = "STRING", mode = "NULLABLE" },
  ])
}

resource "google_bigquery_table" "dim_time" {
  dataset_id          = google_bigquery_dataset.gold.dataset_id
  table_id            = "Dim_Time"
  description         = "Les 48 créneaux de trente minutes d'une journée en heure Europe/London."
  deletion_protection = true

  schema = jsonencode([
    { name = "time_key", type = "INTEGER", mode = "REQUIRED", description = "Clé HHMM, par exemple 30 pour 00:30 et 2330 pour 23:30." },
    { name = "interval_index", type = "INTEGER", mode = "REQUIRED", description = "Index de 0 à 47." },
    { name = "hour", type = "INTEGER", mode = "REQUIRED" },
    { name = "minute", type = "INTEGER", mode = "REQUIRED" },
    { name = "time_label", type = "STRING", mode = "REQUIRED" },
  ])
}

resource "google_bigquery_table" "dim_meter" {
  dataset_id          = google_bigquery_dataset.gold.dataset_id
  table_id            = "Dim_Meter"
  description         = "Dimension SCD2 des compteurs anonymisés du projet Low Carbon London."
  deletion_protection = true

  schema = jsonencode([
    { name = "meter_key", type = "STRING", mode = "REQUIRED" },
    { name = "meter_id", type = "STRING", mode = "REQUIRED" },
    { name = "tariff_type", type = "STRING", mode = "NULLABLE" },
    { name = "acorn_group", type = "STRING", mode = "NULLABLE" },
    { name = "acorn_category", type = "STRING", mode = "NULLABLE" },
    { name = "source_block", type = "STRING", mode = "NULLABLE" },
    { name = "effective_from", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "effective_to", type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "is_current", type = "BOOLEAN", mode = "REQUIRED" },
  ])

  clustering = ["meter_id", "is_current"]
}

resource "google_bigquery_table" "dim_virtual_group" {
  dataset_id          = google_bigquery_dataset.gold.dataset_id
  table_id            = "Dim_Virtual_Group"
  description         = "Cinq groupes techniques déterministes pour le replay des compteurs Londres."
  deletion_protection = true

  schema = jsonencode([
    { name = "virtual_group_id", type = "STRING", mode = "REQUIRED" },
    { name = "group_label", type = "STRING", mode = "REQUIRED" },
    { name = "group_number", type = "INTEGER", mode = "REQUIRED" },
    { name = "grouping_rule", type = "STRING", mode = "REQUIRED" },
  ])
}

resource "google_bigquery_table" "fact_energy_load" {
  dataset_id               = google_bigquery_dataset.gold.dataset_id
  table_id                 = "Fact_Energy_Load"
  description              = "Consommation demi-horaire réelle Londres provenant du batch ou du replay."
  deletion_protection      = true
  require_partition_filter = true

  time_partitioning {
    type  = "DAY"
    field = "event_time"
  }

  clustering = ["meter_id", "virtual_group_id", "source"]

  schema = jsonencode([
    { name = "event_id", type = "STRING", mode = "REQUIRED" },
    { name = "meter_key", type = "STRING", mode = "NULLABLE" },
    { name = "meter_id", type = "STRING", mode = "REQUIRED" },
    { name = "virtual_group_id", type = "STRING", mode = "NULLABLE" },
    { name = "date_key", type = "INTEGER", mode = "REQUIRED", description = "Clé vers Dim_Date en Europe/London." },
    { name = "time_key", type = "INTEGER", mode = "REQUIRED", description = "Clé vers Dim_Time en Europe/London." },
    { name = "event_time", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "ingestion_time", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "energy_kwh", type = "FLOAT", mode = "REQUIRED" },
    { name = "source", type = "STRING", mode = "REQUIRED", description = "BATCH ou STREAM_REPLAY." },
    { name = "quality_status", type = "STRING", mode = "REQUIRED" },
    { name = "source_file", type = "STRING", mode = "NULLABLE" },
    { name = "run_id", type = "STRING", mode = "NULLABLE" },
  ])
}

resource "google_bigquery_table" "fact_weather_obs" {
  dataset_id               = google_bigquery_dataset.gold.dataset_id
  table_id                 = "Fact_Weather_Obs"
  description              = "Observations météo de Londres alignées sur les créneaux de consommation."
  deletion_protection      = true
  require_partition_filter = true

  time_partitioning {
    type  = "DAY"
    field = "observation_time"
  }

  schema = jsonencode([
    { name = "weather_event_id", type = "STRING", mode = "REQUIRED" },
    { name = "observation_time", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "date_key", type = "INTEGER", mode = "REQUIRED" },
    { name = "time_key", type = "INTEGER", mode = "REQUIRED" },
    { name = "temperature_c", type = "FLOAT", mode = "NULLABLE" },
    { name = "apparent_temperature_c", type = "FLOAT", mode = "NULLABLE" },
    { name = "humidity", type = "FLOAT", mode = "NULLABLE" },
    { name = "wind_speed", type = "FLOAT", mode = "NULLABLE" },
    { name = "pressure", type = "FLOAT", mode = "NULLABLE" },
    { name = "weather_summary", type = "STRING", mode = "NULLABLE" },
    { name = "weather_source", type = "STRING", mode = "REQUIRED" },
  ])
}

resource "google_bigquery_table" "fact_load_predictions" {
  dataset_id               = google_bigquery_dataset.gold.dataset_id
  table_id                 = "Fact_Load_Predictions"
  description              = "Prévisions versionnées de consommation par groupe et horizon."
  deletion_protection      = true
  require_partition_filter = true

  time_partitioning {
    type  = "DAY"
    field = "predicted_for"
  }

  clustering = ["virtual_group_id", "model_version"]

  schema = jsonencode([
    { name = "prediction_id", type = "STRING", mode = "REQUIRED" },
    { name = "virtual_group_id", type = "STRING", mode = "REQUIRED" },
    { name = "created_at", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "predicted_for", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "horizon_minutes", type = "INTEGER", mode = "REQUIRED" },
    { name = "predicted_energy_kwh", type = "FLOAT", mode = "REQUIRED" },
    { name = "actual_energy_kwh", type = "FLOAT", mode = "NULLABLE" },
    { name = "absolute_error_kwh", type = "FLOAT", mode = "NULLABLE" },
    { name = "model_version", type = "STRING", mode = "REQUIRED" },
    { name = "run_id", type = "STRING", mode = "REQUIRED" },
  ])
}

resource "google_bigquery_table" "fact_anomalies" {
  dataset_id               = google_bigquery_dataset.gold.dataset_id
  table_id                 = "Fact_Anomalies"
  description              = "Anomalies de consommation et erreurs de prévision détectées à Londres."
  deletion_protection      = true
  require_partition_filter = true

  time_partitioning {
    type  = "DAY"
    field = "detected_at"
  }

  clustering = ["meter_id", "virtual_group_id", "anomaly_type"]

  schema = jsonencode([
    { name = "anomaly_id", type = "STRING", mode = "REQUIRED" },
    { name = "event_id", type = "STRING", mode = "NULLABLE" },
    { name = "meter_id", type = "STRING", mode = "NULLABLE" },
    { name = "virtual_group_id", type = "STRING", mode = "NULLABLE" },
    { name = "detected_at", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "anomaly_type", type = "STRING", mode = "REQUIRED" },
    { name = "severity", type = "STRING", mode = "REQUIRED" },
    { name = "observed_energy_kwh", type = "FLOAT", mode = "NULLABLE" },
    { name = "expected_energy_kwh", type = "FLOAT", mode = "NULLABLE" },
    { name = "anomaly_score", type = "FLOAT", mode = "NULLABLE" },
    { name = "model_version", type = "STRING", mode = "NULLABLE" },
  ])
}
