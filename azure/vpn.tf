# =============================================================================
# AZURE VPN CONFIGURATION - Cross-Cloud Connectivity to GCP
# =============================================================================
# This file creates VPN connectivity between Azure and GCP for Consul
# service mesh communication.
# =============================================================================

# -----------------------------------------------------------------------------
# Public IP for VPN Gateway
# -----------------------------------------------------------------------------
resource "azurerm_public_ip" "vpn" {
  name                = "${var.vnet_name}-vpn-ip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = var.tags
}

# -----------------------------------------------------------------------------
# VPN Gateway
# -----------------------------------------------------------------------------
resource "azurerm_virtual_network_gateway" "vpn" {
  name                = "${var.vnet_name}-vpn-gateway"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  type                = "Vpn"
  vpn_type            = "RouteBased"
  active_active       = false
  enable_bgp          = false
  sku                 = "VpnGw1"
  generation          = "Generation1"

  ip_configuration {
    name                          = "vnetGatewayConfig"
    public_ip_address_id          = azurerm_public_ip.vpn.id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.gateway.id
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Local Network Gateway (Represents GCP VPN Gateway)
# -----------------------------------------------------------------------------
resource "azurerm_local_network_gateway" "gcp" {
  count = var.gcp_vpn_gateway_ip != "" ? 1 : 0

  name                = "gcp-local-gateway"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  gateway_address     = var.gcp_vpn_gateway_ip

  # GCP VPC address spaces
  address_space = [
    "10.0.1.0/24",  # GCP subnet zone A
    "10.0.2.0/24",  # GCP subnet zone B
    "10.1.0.0/16",  # GCP pods CIDR
    "10.2.0.0/16",  # GCP services CIDR
  ]

  tags = var.tags
}

# -----------------------------------------------------------------------------
# VPN Connection to GCP
# -----------------------------------------------------------------------------
resource "azurerm_virtual_network_gateway_connection" "to_gcp" {
  count = var.gcp_vpn_gateway_ip != "" ? 1 : 0

  name                       = "connection-to-gcp"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  type                       = "IPsec"
  virtual_network_gateway_id = azurerm_virtual_network_gateway.vpn.id
  local_network_gateway_id   = azurerm_local_network_gateway.gcp[0].id
  shared_key                 = var.vpn_shared_secret

  # IPsec policy matching GCP defaults
  ipsec_policy {
    dh_group         = "DHGroup14"
    ike_encryption   = "AES256"
    ike_integrity    = "SHA256"
    ipsec_encryption = "AES256"
    ipsec_integrity  = "SHA256"
    pfs_group        = "PFS14"
    sa_datasize      = 102400000
    sa_lifetime      = 3600
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "vpn_gateway_ip" {
  value       = azurerm_public_ip.vpn.ip_address
  description = "Azure VPN Gateway public IP (use this in GCP VPN config)"
}