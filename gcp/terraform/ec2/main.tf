provider "google" {
  project = "project-f1b8c5b4-e5d6-4e9d-9f4"
  zone    = "us-east1-b"
}

data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2204-lts"
  project = "ubuntu-os-cloud"
}

resource "google_compute_instance" "web-server" {
  name         = "web-server"
  machine_type = "e2-small"
  zone         = "us-east1-b"
  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = 50
    }
  }
  network_interface {
    network = "default"
    access_config {}
  }
}