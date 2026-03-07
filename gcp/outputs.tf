# =============================================================================
# GCP OUTPUTS
# =============================================================================
# These outputs provide important information after deployment:
#   - Cluster endpoint for kubectl configuration
#   - Network information for reference
#   - VPN details for Azure connectivity
# =============================================================================

# -----------------------------------------------------------------------------
# Cluster Information
# -----------------------------------------------------------------------------
output "cluster_name" {
  value       = google_container_cluster.primary.name
  description = "GKE cluster name"
}

output "cluster_endpoint" {
  value       = google_container_cluster.primary.endpoint
  description = "GKE cluster API endpoint"
  sensitive   = true
}

output "cluster_ca_certificate" {
  value       = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
  description = "Cluster CA certificate"
  sensitive   = true
}

output "cluster_location" {
  value       = google_container_cluster.primary.location
  description = "Cluster location (region)"
}

# -----------------------------------------------------------------------------
# Network Information
# -----------------------------------------------------------------------------
output "network_name" {
  value       = google_compute_network.vpc.name
  description = "VPC network name"
}

output "subnet_names" {
  value = {
    zone_a = google_compute_subnetwork.subnet_zone_a.name
    zone_b = google_compute_subnetwork.subnet_zone_b.name
  }
  description = "Subnet names for each zone"
}

output "ingress_ip" {
  value       = google_compute_global_address.ingress_ip.address
  description = "Static IP address for GKE Ingress"
}

# -----------------------------------------------------------------------------
# VPN Information (for cross-cloud connectivity)
# -----------------------------------------------------------------------------
output "gcp_vpn_gateway_ip" {
  value       = google_compute_address.vpn_static_ip.address
  description = "GCP VPN Gateway public IP (configure this in Azure)"
}

# -----------------------------------------------------------------------------
# Service Account
# -----------------------------------------------------------------------------
output "node_service_account_email" {
  value       = google_service_account.gke_nodes.email
  description = "Service account email for GKE nodes"
}

# -----------------------------------------------------------------------------
# Kubectl Configuration
# -----------------------------------------------------------------------------
output "configure_kubectl" {
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --region ${var.region} --project ${var.project_id}"
  description = "Run this command to configure kubectl"
}

# -----------------------------------------------------------------------------
# Connection Info for Consul
# -----------------------------------------------------------------------------
output "consul_config" {
  value = {
    datacenter    = "gcp-${var.region}"
    retry_join    = "provider=gce project_name=${var.project_id} tag_value=consul"
    network_cidr  = var.subnet_cidr_zone_a
  }
  description = "Configuration for Consul in GKE"
}