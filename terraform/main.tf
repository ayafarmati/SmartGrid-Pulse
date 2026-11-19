terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.0"
    }
  }
}

variable "project_id" {
  description = "Identifiant du projet GCP de développement, avec facturation active."
  type        = string
}

variable "region" {
  description = "Région du dataset BigQuery."
  type        = string
  default     = "europe-west1"
}

provider "google" {
  project = var.project_id
}

provider "google-beta" {
  project = var.project_id
}

resource "google_project_service" "api" {
  for_each = toset([
    "bigquery.googleapis.com",
    "pubsub.googleapis.com",
  ])

  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}

resource "google_project_service_identity" "pubsub" {
  provider = google-beta
  project  = var.project_id
  service  = google_project_service.api["pubsub.googleapis.com"].service
}
