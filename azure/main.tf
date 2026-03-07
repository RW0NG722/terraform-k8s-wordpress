# =============================================================================
# AZURE MAIN CONFIGURATION - AKS CLUSTER
# =============================================================================
# This file creates:
#   1. Resource Group
#   2. AKS Cluster (Private, with AGIC)
#   3. Application Gateway
#   4. Log Analytics Workspace
#   5. Azure Monitor Integration
#
# DEPLOYMENT STEPS:
#   1. Install Azure CLI and login: az login
#   2. Create terraform.tfvars with your values
#   3. Run: terraform init
#   4. Run: terraform plan
#   5. Run: terraform apply
#
# =============================================================================

terraform {
  required_version = ">= 1.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.0"
    }
  }

  # Uncomment for remote state
  # backend "azurerm" {
  #   resource_group_name  = "terraform-state-rg"
  #   storage_account_name = "yourstorageaccount"
  #   container_name       = "tfstate"
  #   key                  = "aks.tfstate"
  # }
}

# -----------------------------------------------------------------------------
# Provider Configuration
# -----------------------------------------------------------------------------
provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }

  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}

# -----------------------------------------------------------------------------
# Resource Group
# -----------------------------------------------------------------------------
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# -----------------------------------------------------------------------------
# Log Analytics Workspace (for Azure Monitor / Application Insights)
# -----------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "law" {
  name                = "${var.cluster_name}-logs"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics_retention_days

  tags = var.tags
}

# Log Analytics Solution for Containers
resource "azurerm_log_analytics_solution" "containers" {
  solution_name         = "ContainerInsights"
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  workspace_resource_id = azurerm_log_analytics_workspace.law.id
  workspace_name        = azurerm_log_analytics_workspace.law.name

  plan {
    publisher = "Microsoft"
    product   = "OMSGallery/ContainerInsights"
  }
}

# -----------------------------------------------------------------------------
# User Assigned Managed Identity for AKS
# -----------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "aks" {
  name                = "${var.cluster_name}-identity"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  tags                = var.tags
}

# Grant Network Contributor role to AKS identity on VNet
resource "azurerm_role_assignment" "aks_network" {
  scope                = azurerm_virtual_network.vnet.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

# -----------------------------------------------------------------------------
# Public IP for Application Gateway
# -----------------------------------------------------------------------------
resource "azurerm_public_ip" "appgw" {
  name                = "${var.cluster_name}-appgw-ip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Application Gateway (Ingress Controller)
# -----------------------------------------------------------------------------
resource "azurerm_application_gateway" "appgw" {
  name                = "${var.cluster_name}-appgw"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  zones               = ["1", "2", "3"]

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 2
  }

  gateway_ip_configuration {
    name      = "gateway-ip-config"
    subnet_id = azurerm_subnet.appgw.id
  }

  frontend_port {
    name = "https-port"
    port = 443
  }

  frontend_port {
    name = "http-port"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "frontend-ip"
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  # Default backend pool (will be managed by AGIC)
  backend_address_pool {
    name = "default-backend-pool"
  }

  backend_http_settings {
    name                  = "default-http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 60
  }

  http_listener {
    name                           = "http-listener"
    frontend_ip_configuration_name = "frontend-ip"
    frontend_port_name             = "http-port"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "default-routing-rule"
    priority                   = 100
    rule_type                  = "Basic"
    http_listener_name         = "http-listener"
    backend_address_pool_name  = "default-backend-pool"
    backend_http_settings_name = "default-http-settings"
  }

  # SSL/TLS will be configured via AGIC and Kubernetes Ingress

  tags = var.tags

  lifecycle {
    ignore_changes = [
      backend_address_pool,
      backend_http_settings,
      http_listener,
      probe,
      request_routing_rule,
      url_path_map,
      ssl_certificate,
      frontend_port,
      redirect_configuration,
    ]
  }
}

# -----------------------------------------------------------------------------
# AKS Cluster
# -----------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.cluster_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = var.cluster_name

  # Kubernetes version (use stable version)
  kubernetes_version = "1.28"

  # System node pool configuration
  default_node_pool {
    name                = "system"
    vm_size             = var.vm_size  # Standard_D2as_v4
    os_disk_size_gb     = var.os_disk_size_gb
    os_disk_type        = "Managed"
    vnet_subnet_id      = azurerm_subnet.aks.id
    zones               = var.availability_zones  # ["1", "3"] as requested
    enable_auto_scaling = true
    min_count           = var.min_node_count
    max_count           = var.max_node_count
    node_count          = var.min_node_count
    
    # Node labels
    node_labels = {
      "node-type" = "system"
    }

    # Enable host encryption
    enable_host_encryption = false  # Requires feature registration

    # Kubelet configuration
    kubelet_config {
      cpu_manager_policy = "static"
    }

    upgrade_settings {
      max_surge = "33%"
    }

    tags = var.tags
  }

  # Identity configuration
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  # Network configuration - Azure CNI for better performance
  network_profile {
    network_plugin     = "azure"
    network_policy     = "calico"
    service_cidr       = "10.20.0.0/16"
    dns_service_ip     = "10.20.0.10"
    load_balancer_sku  = "standard"
    outbound_type      = "userAssignedNATGateway"
  }

  # Azure Monitor integration (Application Insights / Log Analytics)
  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id
  }

  # Azure Policy add-on
  azure_policy_enabled = true

  # AGIC (Application Gateway Ingress Controller) integration
  ingress_application_gateway {
    gateway_id = azurerm_application_gateway.appgw.id
  }

  # Key Vault integration for secrets
  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  # Workload Identity (preview)
  workload_identity_enabled = true
  oidc_issuer_enabled       = true

  # Azure AD RBAC integration
  azure_active_directory_role_based_access_control {
    managed                = true
    azure_rbac_enabled     = true
  }

  # Auto-upgrade channel
  automatic_channel_upgrade = "patch"

  # Maintenance window
  maintenance_window {
    allowed {
      day   = "Sunday"
      hours = [2, 3, 4]
    }
  }

  tags = var.tags

  depends_on = [
    azurerm_role_assignment.aks_network,
    azurerm_application_gateway.appgw,
    azurerm_subnet_nat_gateway_association.aks,
  ]
}

# -----------------------------------------------------------------------------
# Grant AKS access to Application Gateway
# -----------------------------------------------------------------------------
resource "azurerm_role_assignment" "aks_agic" {
  scope                = azurerm_application_gateway.appgw.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_kubernetes_cluster.aks.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
}

resource "azurerm_role_assignment" "aks_agic_rg" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Reader"
  principal_id         = azurerm_kubernetes_cluster.aks.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
}