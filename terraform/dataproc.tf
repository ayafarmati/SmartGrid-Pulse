resource "google_project_service" "dataproc" {
  for_each = toset([
    "bigquerystorage.googleapis.com",
    "compute.googleapis.com",
    "dataproc.googleapis.com",
    "dataprocrm.googleapis.com",
  ])

  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}
