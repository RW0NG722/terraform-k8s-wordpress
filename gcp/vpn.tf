# =============================================================================
# GCP VPN CONFIGURATION - Cross-Cloud Connectivity to Azure
# =============================================================================
# This file creates VPN connectivity between GCP and Azure for Consul
# service mesh communication.
#
# Architecture:
#   GCP VPC ←──── VPN Tunnel ────→ Azure VNet
#     │                              │
#   GKE Cluster                  AKS Cluster
#     │                              │
#   Consul Server              Consul Server
#     └─────── Service Mesh ─────────┘
#
# =============================================================================

# -----------------------------------------------------------------------------
# VPN Gateway
# -----------------------------------------------------------------------------
resource "google_compute_vpn_gateway" "vpn_gateway" {
  name    = "${var.network_name}-vpn-gateway"
  project = var.project_id
  region  = var.region
  network = google_compute_network.vpc.id
}

# -----------------------------------------------------------------------------
# Static IP for VPN Gateway
# -----------------------------------------------------------------------------
resource "google_compute_address" "vpn_static_ip" {
  name    = "${var.network_name}-vpn-ip"
  project = var.project_id
  region  = var.region
}

# -----------------------------------------------------------------------------
# Forwarding Rules for VPN Protocols
# -----------------------------------------------------------------------------
resource "google_compute_forwarding_rule" "vpn_esp" {
  name        = "${var.network_name}-vpn-esp"
  project     = var.project_id
  region      = var.region
  ip_protocol = "ESP"
  ip_address  = google_compute_address.vpn_static_ip.address
  target      = google_compute_vpn_gateway.vpn_gateway.self_link
}

resource "google_compute_forwarding_rule" "vpn_udp500" {
  name        = "${var.network_name}-vpn-udp500"
  project     = var.project_id
  region      = var.region
  ip_protocol = "UDP"
  port_range  = "500"
  ip_address  = google_compute_address.vpn_static_ip.address
  target      = google_compute_vpn_gateway.vpn_gateway.self_link
}

resource "google_compute_forwarding_rule" "vpn_udp4500" {
  name        = "${var.network_name}-vpn-udp4500"
  project     = var.project_id
  region      = var.region
  ip_protocol = "UDP"
  port_range  = "4500"
  ip_address  = google_compute_address.vpn_static_ip.address
  target      = google_compute_vpn_gateway.vpn_gateway.self_link
}

# -----------------------------------------------------------------------------
# VPN Tunnel to Azure (Configure after Azure VPN Gateway is created)
# -----------------------------------------------------------------------------
resource "google_compute_vpn_tunnel" "to_azure" {
  count = var.azure_vpn_gateway_ip != "" ? 1 : 0

  name               = "${var.network_name}-tunnel-to-azure"
  project            = var.project_id
  region             = var.region
  peer_ip            = var.azure_vpn_gateway_ip
  shared_secret      = var.vpn_shared_secret
  target_vpn_gateway = google_compute_vpn_gateway.vpn_gateway.self_link

  local_traffic_selector  = ["0.0.0.0/0"]
  remote_traffic_selector = ["0.0.0.0/0"]

  depends_on = [
    google_compute_forwarding_rule.vpn_esp,
    google_compute_forwarding_rule.vpn_udp500,
    google_compute_forwarding_rule.vpn_udp4500,
  ]
}

# -----------------------------------------------------------------------------
# Route to Azure VNet via VPN Tunnel
# -----------------------------------------------------------------------------
resource "google_compute_route" "to_azure" {
  count = var.azure_vpn_gateway_ip != "" ? 1 : 0

  name                = "${var.network_name}-route-to-azure"
  project             = var.project_id
  network             = google_compute_network.vpc.name
  dest_range          = "10.10.0.0/16"  # Azure VNet CIDR
  priority            = 1000
  next_hop_vpn_tunnel = google_compute_vpn_tunnel.to_azure[0].self_link
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "vpn_gateway_ip" {
  value       = google_compute_address.vpn_static_ip.address
  description = "GCP VPN Gateway public IP (use this in Azure VPN config)"
}