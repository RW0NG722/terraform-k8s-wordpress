# =============================================================================
# AZURE VARIABLES
# =============================================================================
# This file defines all variables used in Azure Terraform configuration.
#
# USAGE:
#   1. Copy terraform.tfvars.example to terraform.tfvars
#   2. Fill in your values  
#   3. Run: terraform init && terraform plan
# =============================================================================

variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "tenant_id" {
  description = "Azure Tenant ID"
  type        = string
}

variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "eastasia"
  # eastasia = Hong Kong region (close to GCP asia-east2)
}

variable "resource_group_name" {
  description = "Name of the Azure Resource Group"
  type        = string
  default     = "wordpress-aks-rg"
}

variable "cluster_name" {
  description = "Name of the AKS cluster"
  type        = string
  default     = "wordpress-aks-cluster"
}

# -----------------------------------------------------------------------------
# Network Configuration
# -----------------------------------------------------------------------------
variable "vnet_name" {
  description = "Name of the Virtual Network"
  type        = string
  default     = "wordpress-vnet"
}

variable "vnet_cidr" {
  description = "CIDR range for the VNet"
  type        = string
  default     = "10.10.0.0/16"
}

variable "subnet_cidr_zone_1" {
  description = "CIDR range for subnet in availability zone 1"
  type        = string
  default     = "10.10.1.0/24"
}

variable "subnet_cidr_zone_3" {
  description = "CIDR range for subnet in availability zone 3"
  type        = string
  default     = "10.10.3.0/24"
}

variable "appgw_subnet_cidr" {
  description = "CIDR range for Application Gateway subnet"
  type        = string
  default     = "10.10.100.0/24"
}

# -----------------------------------------------------------------------------
# Node Pool Configuration
# -----------------------------------------------------------------------------
variable "vm_size" {
  description = "Azure VM size for AKS nodes"
  type        = string
  default     = "Standard_D2as_v4"
  # Standard_D2as_v4: 2 vCPU, 8GB RAM
  # This matches the autoscaler requirement of max 8GB RAM, 4 CPU per instance
  #
  # AMD-based D-series v4:
  # - Standard_D2as_v4:  2 vCPU, 8GB RAM
  # - Standard_D4as_v4:  4 vCPU, 16GB RAM
  # - Standard_D8as_v4:  8 vCPU, 32GB RAM
}

variable "os_disk_size_gb" {
  description = "OS disk size in GB for each node"
  type        = number
  default     = 50
  # Minimum recommended for AKS is 30GB, default is 128GB
}

variable "availability_zones" {
  description = "Availability zones for AKS nodes"
  type        = list(string)
  default     = ["1", "3"]
  # As requested: zones 1 and 3 in eastasia
  # Each zone represents a separate fault domain
}

variable "min_node_count" {
  description = "Minimum number of nodes for autoscaling"
  type        = number
  default     = 1
}

variable "max_node_count" {
  description = "Maximum number of nodes for autoscaling"
  type        = number
  default     = 2
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
# SSL/TLS Configuration
# -----------------------------------------------------------------------------
variable "domain_name" {
  description = "Domain name for the WordPress application"
  type        = string
  # Example: "wordpress-azure.example.com"
}

# -----------------------------------------------------------------------------
# VPN Configuration (for cross-cloud Consul)
# -----------------------------------------------------------------------------
variable "vpn_shared_secret" {
  description = "Shared secret for VPN tunnel to GCP"
  type        = string
  sensitive   = true
}

variable "gcp_vpn_gateway_ip" {
  description = "Public IP of GCP VPN Gateway (set after GCP deployment)"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Tags
# -----------------------------------------------------------------------------
variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    ManagedBy   = "Terraform"
    Application = "WordPress"
    Environment = "Production"
  }
}

# -----------------------------------------------------------------------------
# Log Analytics
# -----------------------------------------------------------------------------
variable "log_analytics_retention_days" {
  description = "Retention period for Log Analytics workspace"
  type        = number
  default     = 30
}