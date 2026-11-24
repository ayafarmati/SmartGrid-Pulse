variable "keep_legacy_silver_calendar" {
  description = "Conserve les anciennes dimensions Silver pendant la migration vers Gold."
  type        = bool
  default     = false
}

variable "keep_legacy_silver_load" {
  description = "Conserve le fait de charge Silver pendant la migration vers Gold."
  type        = bool
  default     = false
}

locals {
  dim_date_schema = jsonencode([
    { name = "date_key", type = "INTEGER", mode = "REQUIRED", description = "Date locale au format AAAAMMJJ." },
    { name = "full_date", type = "DATE", mode = "REQUIRED" },
    { name = "year", type = "INTEGER", mode = "REQUIRED" },
    { name = "month", type = "INTEGER", mode = "REQUIRED" },
    { name = "month_name", type = "STRING", mode = "REQUIRED" },
    { name = "day", type = "INTEGER", mode = "REQUIRED" },
    { name = "day_of_week", type = "INTEGER", mode = "REQUIRED", description = "Lundi = 1, dimanche = 7." },
    { name = "is_weekend", type = "BOOLEAN", mode = "REQUIRED" },
    { name = "is_holiday_spain", type = "BOOLEAN", mode = "NULLABLE", description = "NULL tant que le calendrier officiel n’est pas chargé." },
    { name = "season", type = "STRING", mode = "REQUIRED" },
  ])

  dim_time_schema = jsonencode([
    { name = "time_key", type = "INTEGER", mode = "REQUIRED", description = "Heure locale au format numérique HHMM." },
    { name = "hour_24", type = "INTEGER", mode = "REQUIRED" },
    { name = "minute", type = "INTEGER", mode = "REQUIRED" },
    { name = "period_of_day", type = "STRING", mode = "REQUIRED" },
    { name = "is_peak_hour", type = "BOOLEAN", mode = "REQUIRED", description = "Créneaux métier de 08 h à 12 h et de 18 h à 22 h, fin exclue." },
  ])
}

resource "google_bigquery_dataset" "gold" {
  dataset_id  = "gold_smartgrid"
  location    = google_bigquery_dataset.silver.location
  description = "Dimensions métier, variables et résultats analytiques SmartGrid Pulse."
}

resource "google_bigquery_table" "gold_dim_date" {
  dataset_id          = google_bigquery_dataset.gold.dataset_id
  table_id            = "Dim_Date"
  description         = "Calendrier métier espagnol, une ligne par date locale."
  deletion_protection = true
  schema              = local.dim_date_schema
}

resource "google_bigquery_table" "gold_dim_time" {
  dataset_id          = google_bigquery_dataset.gold.dataset_id
  table_id            = "Dim_Time"
  description         = "Heures de la journée métier espagnole, une ligne par minute locale."
  deletion_protection = true
  schema              = local.dim_time_schema
}

# Garde les tables déjà déployées sous gestion Terraform pendant la transition.
moved {
  from = google_bigquery_table.dim_date
  to   = google_bigquery_table.dim_date[0]
}

moved {
  from = google_bigquery_table.dim_time
  to   = google_bigquery_table.dim_time[0]
}

resource "google_bigquery_table" "dim_date" {
  count = var.keep_legacy_silver_calendar ? 1 : 0

  dataset_id          = google_bigquery_dataset.silver.dataset_id
  table_id            = "Dim_Date"
  description         = "Calendrier métier espagnol, une ligne par date locale."
  deletion_protection = true
  schema              = local.dim_date_schema

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_bigquery_table" "dim_time" {
  count = var.keep_legacy_silver_calendar ? 1 : 0

  dataset_id          = google_bigquery_dataset.silver.dataset_id
  table_id            = "Dim_Time"
  description         = "Heures de la journée métier espagnole, une ligne par minute locale."
  deletion_protection = true
  schema              = local.dim_time_schema

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  fact_energy_load_schema = jsonencode([
    { name = "load_key", type = "STRING", mode = "REQUIRED", description = "Identifiant SHA-256 stable calculé sur le pays et l’heure UTC." },
    { name = "date_key", type = "INTEGER", mode = "REQUIRED", description = "Clé vers Dim_Date en Europe/Madrid." },
    { name = "time_key", type = "INTEGER", mode = "REQUIRED", description = "Clé vers Dim_Time en Europe/Madrid." },
    { name = "timestamp_utc", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "actual_load_mw", type = "FLOAT", mode = "REQUIRED" },
    { name = "forecast_load_mw", type = "FLOAT", mode = "NULLABLE", description = "Prévision du gestionnaire fournie par la source." },
    { name = "load_delta_mw", type = "FLOAT", mode = "NULLABLE", description = "Charge réelle moins prévision de référence." },
    { name = "price_spot_eur_mwh", type = "FLOAT", mode = "NULLABLE" },
    { name = "generation_solar_mw", type = "FLOAT", mode = "NULLABLE" },
    { name = "generation_wind_onshore_mw", type = "FLOAT", mode = "NULLABLE" },
    { name = "generation_hydro_mw", type = "FLOAT", mode = "NULLABLE" },
    { name = "generation_gas_mw", type = "FLOAT", mode = "NULLABLE" },
    { name = "generation_nuclear_mw", type = "FLOAT", mode = "NULLABLE" },
    { name = "generation_coal_mw", type = "FLOAT", mode = "NULLABLE" },
    { name = "total_generation_mw", type = "FLOAT", mode = "NULLABLE" },
    { name = "renewable_share_pct", type = "FLOAT", mode = "NULLABLE" },
    { name = "grid_balance_mw", type = "FLOAT", mode = "NULLABLE", description = "Production totale moins charge réelle." },
  ])
}

resource "google_bigquery_table" "gold_fact_energy_load" {
  dataset_id               = google_bigquery_dataset.gold.dataset_id
  table_id                 = "Fact_Energy_Load"
  description              = "Charge, production et prix espagnols, une ligne nationale par heure UTC."
  deletion_protection      = true
  require_partition_filter = true
  clustering               = ["time_key"]
  schema                   = local.fact_energy_load_schema

  time_partitioning {
    type  = "DAY"
    field = "timestamp_utc"
  }
}

moved {
  from = google_bigquery_table.fact_energy_load
  to   = google_bigquery_table.fact_energy_load[0]
}

resource "google_bigquery_table" "fact_energy_load" {
  count = var.keep_legacy_silver_load ? 1 : 0

  dataset_id               = google_bigquery_dataset.silver.dataset_id
  table_id                 = "Fact_Energy_Load"
  description              = "Charge, production et prix espagnols, une ligne nationale par heure UTC."
  deletion_protection      = true
  require_partition_filter = true
  clustering               = ["time_key"]
  schema                   = local.fact_energy_load_schema

  time_partitioning {
    type  = "DAY"
    field = "timestamp_utc"
  }

  lifecycle {
    prevent_destroy = true
  }
}
