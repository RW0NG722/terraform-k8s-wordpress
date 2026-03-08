# =============================================================================
# GCP VARIABLES
# =============================================================================
# This file defines all variables used in GCP Terraform configuration.
# 
# USAGE:
#   1. Copy terraform.tfvars.example to terraform.tfvars
#   2. Fill in your values
#   3. Run: terraform init && terraform plan
# =============================================================================

variable "project_id" {
  description = "GCP Project ID where resources will be created"
  type        = string
  # Example: "my-gcp-project-123456"
}

variable "region" {
  description = "GCP region for the GKE cluster (regional cluster for HA)"
  type        = string
  default     = "asia-east2"
  # Note: Using regional cluster instead of zonal to support multiple subnets
  # asia-east2 = Hong Kong region
}

variable "zones" {
  description = "Zones within the region for node distribution (1 VM per zone/subnet)"
  type        = list(string)
  default     = ["asia-east2-a", "asia-east2-b"]
  # Each zone will have its own subnet, fulfilling the 2 subnet requirement
}

variable "cluster_name" {
  description = "Name of the GKE cluster"
  type        = string
  default     = "wordpress-gke-cluster"
}

variable "network_name" {
  description = "Name of the VPC network"
  type        = string
  default     = "wordpress-vpc"
}

# -----------------------------------------------------------------------------
# Node Pool Configuration
# -----------------------------------------------------------------------------
variable "machine_type" {
  description = "Machine type for GKE nodes"
  type        = string
  default     = "e2-medium"
  

variable "disk_size_gb" {
  description = "Disk size in GB for each node"
  type        = number
  default     = 30 
}

variable "disk_type" {
  description = "Disk type for GKE nodes"
  type        = string
  default     = "pd-standard"
  # Options: pd-standard (HDD), pd-ssd (SSD), pd-balanced
}

variable "min_node_count" {
  description = "Minimum number of nodes per zone"
  type        = number
  default     = 1
  # With 2 zones, total minimum = 2 nodes (1 per zone = 1 per subnet)
}

variable "max_node_count" {
  description = "Maximum number of nodes per zone for autoscaling"
  type        = number
  default     = 2
  # With 2 zones, total maximum = 4 nodes
}

# -----------------------------------------------------------------------------
# Autoscaler Resource Limits
# -----------------------------------------------------------------------------
variable "autoscaler_max_cpu" {
  description = "Maximum CPU cores per node for autoscaler decisions"
  type        = number
  default     = 4
}

variable "autoscaler_max_memory_gb" {
  description = "Maximum memory in GB per node for autoscaler decisions"
  type        = number
  default     = 8
}

# -----------------------------------------------------------------------------
# Network Configuration
# -----------------------------------------------------------------------------
variable "subnet_cidr_zone_a" {
  description = "CIDR range for subnet in zone A"
  type        = string
  default     = "10.0.1.0/24"
}

variable "subnet_cidr_zone_b" {
  description = "CIDR range for subnet in zone B"
  type        = string
  default     = "10.0.2.0/24"
}

variable "pods_cidr" {
  description = "Secondary CIDR range for Kubernetes pods"
  type        = string
  default     = "10.1.0.0/16"
}

variable "services_cidr" {
  description = "Secondary CIDR range for Kubernetes services"
  type        = string
  default     = "10.2.0.0/16"
}

variable "master_cidr" {
  description = "CIDR range for GKE master nodes (private cluster)"
  type        = string
  default     = "172.16.0.0/28"
}

# -----------------------------------------------------------------------------
# SSL/TLS Configuration
# -----------------------------------------------------------------------------
variable "domain_name" {
  description = "Domain name for the WordPress application"
  type        = string
  # Example: "wordpress.example.com"
}

# -----------------------------------------------------------------------------
# VPN Configuration (for cross-cloud Consul)
# -----------------------------------------------------------------------------
variable "vpn_shared_secret" {
  description = "Shared secret for VPN tunnel to Azure"
  type        = string
  sensitive   = true
}

variable "azure_vpn_gateway_ip" {
  description = "Public IP of Azure VPN Gateway (set after Azure deployment)"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Labels and Tags
# -----------------------------------------------------------------------------
variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "prod"
}

variable "labels" {
  description = "Labels to apply to all resources"
  type        = map(string)
  default = {
    managed_by  = "terraform"
    application = "wordpress"
  }
}