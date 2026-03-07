# =============================================================================
# GCP MAIN CONFIGURATION - GKE CLUSTER
# =============================================================================
# This file creates:
#   1. GKE Cluster (Private, Regional)
#   2. Node Pool with Autoscaling
#   3. Workload Identity (for secure service account binding)
#   4. Cloud Logging & Monitoring Integration
#
# DEPLOYMENT STEPS:
#   1. Ensure you have gcloud CLI installed and authenticated
#   2. Enable required APIs: container.googleapis.com, compute.googleapis.com
#   3. Create terraform.tfvars with your values
#   4. Run: terraform init
#   5. Run: terraform plan
#   6. Run: terraform apply
#
# =============================================================================

terraform {
  required_version = ">= 1.0.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.0"
    }
  }

  # Uncomment to use remote state (recommended for production)
  # backend "gcs" {
  #   bucket = "your-terraform-state-bucket"
  #   prefix = "terraform/gke"
  # }
}

# -----------------------------------------------------------------------------
# Provider Configuration
# -----------------------------------------------------------------------------
provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# -----------------------------------------------------------------------------
# Enable Required GCP APIs
# -----------------------------------------------------------------------------
resource "google_project_service" "required_apis" {
  for_each = toset([
    "container.googleapis.com",           # GKE
    "compute.googleapis.com",             # Compute Engine
    "logging.googleapis.com",             # Cloud Logging (Stackdriver)
    "monitoring.googleapis.com",          # Cloud Monitoring
    "cloudresourcemanager.googleapis.com", # Resource Manager
    "iam.googleapis.com",                 # IAM
    "servicenetworking.googleapis.com",   # Service Networking
  ])

  project = var.project_id
  service = each.value

  disable_on_destroy = false
}

# -----------------------------------------------------------------------------
# Service Account for GKE Nodes
# -----------------------------------------------------------------------------
resource "google_service_account" "gke_nodes" {
  account_id   = "${var.cluster_name}-nodes"
  display_name = "GKE Nodes Service Account for ${var.cluster_name}"
  project      = var.project_id
}

# Grant necessary permissions to the node service account
resource "google_project_iam_member" "gke_node_roles" {
  for_each = toset([
    "roles/logging.logWriter",        # Write logs to Cloud Logging
    "roles/monitoring.metricWriter",  # Write metrics to Cloud Monitoring
    "roles/monitoring.viewer",        # View monitoring data
    "roles/storage.objectViewer",     # Pull container images from GCR
    "roles/artifactregistry.reader",  # Pull images from Artifact Registry
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# -----------------------------------------------------------------------------
# GKE Cluster (Private, Regional)
# -----------------------------------------------------------------------------
resource "google_container_cluster" "primary" {
  provider = google-beta

  name     = var.cluster_name
  project  = var.project_id
  location = var.region  # Regional cluster for HA across zones

  # Specify zones for the cluster
  node_locations = var.zones

  # We'll create a separate node pool, so remove the default
  remove_default_node_pool = true
  initial_node_count       = 1

  # Network configuration - uses the VPC we created
  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.subnet_zone_a.name

  # IP allocation for pods and services
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods-range-a"
    services_secondary_range_name = "services-range-a"
  }

  # Private cluster configuration - nodes have no public IPs
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false  # Allow kubectl from internet (via authorized networks)
    master_ipv4_cidr_block  = var.master_cidr
  }

  # Authorized networks that can access the Kubernetes API
  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "0.0.0.0/0"  # Restrict this in production!
      display_name = "All networks"
    }
  }

  # Workload Identity - best practice for GKE security
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Cluster-level logging and monitoring (sends to Cloud Logging/Stackdriver)
  logging_config {
    enable_components = [
      "SYSTEM_COMPONENTS",
      "WORKLOADS"  # This sends application logs to Cloud Logging
    ]
  }

  monitoring_config {
    enable_components = [
      "SYSTEM_COMPONENTS",
      "WORKLOADS"
    ]

    managed_prometheus {
      enabled = true
    }
  }

  # Addons configuration
  addons_config {
    # Enable HTTP Load Balancing for GKE Ingress
    http_load_balancing {
      disabled = false
    }

    # Horizontal Pod Autoscaling
    horizontal_pod_autoscaling {
      disabled = false
    }

    # GCE Persistent Disk CSI Driver for PersistentVolumes
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }

    # Network Policy (Calico)
    network_policy_config {
      disabled = false
    }
  }

  # Network Policy
  network_policy {
    enabled  = true
    provider = "CALICO"
  }

  # Maintenance window - applies updates during low-traffic hours
  maintenance_policy {
    daily_maintenance_window {
      start_time = "03:00"  # 3 AM UTC
    }
  }

  # Cluster autoscaling configuration
  cluster_autoscaling {
    enabled = true

    # Resource limits for the entire cluster
    resource_limits {
      resource_type = "cpu"
      minimum       = 2   # Minimum total CPUs across all nodes
      maximum       = 16  # Maximum total CPUs
    }

    resource_limits {
      resource_type = "memory"
      minimum       = 4   # Minimum total memory in GB
      maximum       = 32  # Maximum total memory in GB
    }

    auto_provisioning_defaults {
      service_account = google_service_account.gke_nodes.email
      oauth_scopes = [
        "https://www.googleapis.com/auth/cloud-platform"
      ]
    }
  }

  # Release channel for automatic upgrades
  release_channel {
    channel = "REGULAR"
  }

  # Binary Authorization (optional - for container security)
  # binary_authorization {
  #   evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
  # }

  resource_labels = var.labels

  depends_on = [
    google_project_service.required_apis,
    google_compute_subnetwork.subnet_zone_a,
    google_compute_subnetwork.subnet_zone_b,
  ]
}

# -----------------------------------------------------------------------------
# GKE Node Pool with Autoscaling
# -----------------------------------------------------------------------------
resource "google_container_node_pool" "primary_nodes" {
  provider = google-beta

  name       = "${var.cluster_name}-node-pool"
  project    = var.project_id
  location   = var.region
  cluster    = google_container_cluster.primary.name

  # Node count per zone - with 2 zones, total = 2 * node_count
  node_count = var.min_node_count

  # Autoscaling configuration
  autoscaling {
    min_node_count  = var.min_node_count  # Minimum nodes per zone
    max_node_count  = var.max_node_count  # Maximum nodes per zone
    location_policy = "BALANCED"          # Distribute evenly across zones
  }

  # Node management
  management {
    auto_repair  = true  # Automatically repair unhealthy nodes
    auto_upgrade = true  # Automatically upgrade nodes
  }

  # Node configuration
  node_config {
    # Machine type - e2-standard-2: 2 vCPU, 8GB RAM
    # CORRECTED from e2-medium to match autoscaler requirements
    machine_type = var.machine_type

    # Disk configuration
    # CORRECTED: 50GB instead of 10GB (10GB is too small for K8s)
    disk_size_gb = var.disk_size_gb
    disk_type    = var.disk_type

    # Service account for nodes
    service_account = google_service_account.gke_nodes.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    # Workload Identity
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    # Metadata
    metadata = {
      disable-legacy-endpoints = "true"
    }

    # Labels for nodes
    labels = merge(var.labels, {
      node_pool = "primary"
    })

    # Tags for firewall rules
    tags = [
      "gke-${var.cluster_name}",
      "consul"
    ]

    # Shielded Instance Config (security)
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  # Upgrade settings
  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  lifecycle {
    ignore_changes = [
      node_count,  # Ignore changes since autoscaler manages this
    ]
  }
}

# -----------------------------------------------------------------------------
# Kubernetes Provider Configuration (for deploying K8s resources)
# -----------------------------------------------------------------------------
data "google_client_config" "default" {}

# This output can be used by other modules to configure kubectl
output "kubeconfig_command" {
  value       = "gcloud container clusters get-credentials ${var.cluster_name} --region ${var.region} --project ${var.project_id}"
  description = "Command to configure kubectl for this cluster"
}