# =============================================================================
# GCP NETWORK CONFIGURATION
# =============================================================================
# This file creates:
#   1. VPC Network
#   2. Two Private Subnets (one per zone for GKE nodes)
#   3. Cloud NAT (for private nodes to access internet)
#   4. Firewall Rules
#   5. Cloud Router (for NAT and VPN)
#
# Architecture:
#   ┌─────────────────────────────────────────────────────────────────────┐
#   │                         VPC: wordpress-vpc                          │
#   │  ┌──────────────────────┐       ┌──────────────────────┐           │
#   │  │ Subnet A (zone-a)    │       │ Subnet B (zone-b)    │           │
#   │  │ 10.0.1.0/24          │       │ 10.0.2.0/24          │           │
#   │  │ ┌──────────────────┐ │       │ ┌──────────────────┐ │           │
#   │  │ │   GKE Node 1     │ │       │ │   GKE Node 2     │ │           │
#   │  │ │   (Private IP)   │ │       │ │   (Private IP)   │ │           │
#   │  │ └──────────────────┘ │       │ └──────────────────┘ │           │
#   │  └──────────────────────┘       └──────────────────────┘           │
#   │                              │                                      │
#   │                        Cloud NAT                                    │
#   │                              │                                      │
#   └──────────────────────────────┼──────────────────────────────────────┘
#                                  │
#                              Internet
# =============================================================================

# -----------------------------------------------------------------------------
# VPC Network
# -----------------------------------------------------------------------------
resource "google_compute_network" "vpc" {
  name                    = var.network_name
  project                 = var.project_id
  auto_create_subnetworks = false  # We create custom subnets
  routing_mode            = "REGIONAL"
  description             = "VPC for WordPress GKE cluster with private subnets"
}

# -----------------------------------------------------------------------------
# Private Subnet for Zone A
# -----------------------------------------------------------------------------
resource "google_compute_subnetwork" "subnet_zone_a" {
  name                     = "${var.network_name}-subnet-a"
  project                  = var.project_id
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = var.subnet_cidr_zone_a
  private_ip_google_access = true  # Allows private nodes to access Google APIs

  # Secondary ranges for GKE pods and services
  secondary_ip_range {
    range_name    = "pods-range-a"
    ip_cidr_range = "10.1.0.0/17"  # First half of pods CIDR
  }

  secondary_ip_range {
    range_name    = "services-range-a"
    ip_cidr_range = "10.2.0.0/20"  # First part of services CIDR
  }

  description = "Private subnet in ${var.zones[0]} for GKE nodes"

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# -----------------------------------------------------------------------------
# Private Subnet for Zone B
# -----------------------------------------------------------------------------
resource "google_compute_subnetwork" "subnet_zone_b" {
  name                     = "${var.network_name}-subnet-b"
  project                  = var.project_id
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = var.subnet_cidr_zone_b
  private_ip_google_access = true

  # Secondary ranges for GKE pods and services
  secondary_ip_range {
    range_name    = "pods-range-b"
    ip_cidr_range = "10.1.128.0/17"  # Second half of pods CIDR
  }

  secondary_ip_range {
    range_name    = "services-range-b"
    ip_cidr_range = "10.2.16.0/20"  # Second part of services CIDR
  }

  description = "Private subnet in ${var.zones[1]} for GKE nodes"

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# -----------------------------------------------------------------------------
# Cloud Router (required for Cloud NAT and VPN)
# -----------------------------------------------------------------------------
resource "google_compute_router" "router" {
  name    = "${var.network_name}-router"
  project = var.project_id
  region  = var.region
  network = google_compute_network.vpc.id

  bgp {
    asn               = 64514  # Private ASN for BGP
    advertise_mode    = "CUSTOM"
    advertised_groups = ["ALL_SUBNETS"]
  }
}

# -----------------------------------------------------------------------------
# Cloud NAT (allows private nodes to access internet for pulling images, etc.)
# -----------------------------------------------------------------------------
resource "google_compute_router_nat" "nat" {
  name                               = "${var.network_name}-nat"
  project                            = var.project_id
  region                             = var.region
  router                             = google_compute_router.router.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }

  # Timeouts for NAT connections
  min_ports_per_vm                   = 64
  tcp_established_idle_timeout_sec   = 1200
  tcp_transitory_idle_timeout_sec    = 30
  udp_idle_timeout_sec               = 30
}

# -----------------------------------------------------------------------------
# Firewall Rules
# -----------------------------------------------------------------------------

# Allow internal communication within VPC
resource "google_compute_firewall" "allow_internal" {
  name    = "${var.network_name}-allow-internal"
  project = var.project_id
  network = google_compute_network.vpc.id

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = [
    var.subnet_cidr_zone_a,
    var.subnet_cidr_zone_b,
    var.pods_cidr,
    var.services_cidr
  ]

  description = "Allow all internal traffic within VPC"
}

# Allow health checks from Google Load Balancer
resource "google_compute_firewall" "allow_health_checks" {
  name    = "${var.network_name}-allow-health-checks"
  project = var.project_id
  network = google_compute_network.vpc.id

  allow {
    protocol = "tcp"
  }

  # Google Load Balancer health check IP ranges
  source_ranges = [
    "35.191.0.0/16",
    "130.211.0.0/22",
    "209.85.152.0/22",
    "209.85.204.0/22"
  ]

  target_tags = ["gke-${var.cluster_name}"]

  description = "Allow Google Load Balancer health checks"
}

# Allow SSH from IAP (Identity-Aware Proxy) for secure node access
resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "${var.network_name}-allow-iap-ssh"
  project = var.project_id
  network = google_compute_network.vpc.id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # IAP IP range
  source_ranges = ["35.235.240.0/20"]

  description = "Allow SSH access via Identity-Aware Proxy"
}

# Allow GKE master to communicate with nodes
resource "google_compute_firewall" "allow_master_to_nodes" {
  name    = "${var.network_name}-allow-master"
  project = var.project_id
  network = google_compute_network.vpc.id

  allow {
    protocol = "tcp"
    ports    = ["443", "10250", "8443"]
  }

  source_ranges = [var.master_cidr]
  target_tags   = ["gke-${var.cluster_name}"]

  description = "Allow GKE master to communicate with worker nodes"
}

# Allow Consul ports for cross-cloud communication
resource "google_compute_firewall" "allow_consul" {
  name    = "${var.network_name}-allow-consul"
  project = var.project_id
  network = google_compute_network.vpc.id

  allow {
    protocol = "tcp"
    ports    = ["8300", "8301", "8302", "8500", "8501", "8502", "8600"]
  }

  allow {
    protocol = "udp"
    ports    = ["8301", "8302", "8600"]
  }

  source_ranges = [
    var.subnet_cidr_zone_a,
    var.subnet_cidr_zone_b,
    "10.10.0.0/16"  # Azure VNet CIDR (for cross-cloud Consul)
  ]

  target_tags = ["consul"]

  description = "Allow Consul service mesh communication"
}

# -----------------------------------------------------------------------------
# Static IP for Ingress (optional, for stable external IP)
# -----------------------------------------------------------------------------
resource "google_compute_global_address" "ingress_ip" {
  name        = "${var.cluster_name}-ingress-ip"
  project     = var.project_id
  description = "Static IP for GKE Ingress"
}

# -----------------------------------------------------------------------------
# Outputs used by other modules
# -----------------------------------------------------------------------------
output "vpc_id" {
  value       = google_compute_network.vpc.id
  description = "VPC Network ID"
}

output "vpc_name" {
  value       = google_compute_network.vpc.name
  description = "VPC Network Name"
}

output "subnet_zone_a_name" {
  value       = google_compute_subnetwork.subnet_zone_a.name
  description = "Subnet A Name"
}

output "subnet_zone_b_name" {
  value       = google_compute_subnetwork.subnet_zone_b.name
  description = "Subnet B Name"
}

output "router_name" {
  value       = google_compute_router.router.name
  description = "Cloud Router Name"
}

output "ingress_static_ip" {
  value       = google_compute_global_address.ingress_ip.address
  description = "Static IP for Ingress"
}