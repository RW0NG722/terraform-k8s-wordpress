# =============================================================================
# AZURE NETWORK CONFIGURATION
# =============================================================================
# This file creates:
#   1. Virtual Network (VNet)
#   2. Two Private Subnets (one per availability zone)
#   3. Application Gateway Subnet
#   4. Network Security Groups
#   5. NAT Gateway (for private nodes)
#
# Architecture:
#   ┌─────────────────────────────────────────────────────────────────────┐
#   │                      VNet: wordpress-vnet                           │
#   │                         10.10.0.0/16                                │
#   │                                                                     │
#   │  ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────────┐   │
#   │  │ AKS Subnet      │ │ AKS Subnet      │ │ AppGW Subnet        │   │
#   │  │ Zone 1          │ │ Zone 3          │ │ 10.10.100.0/24      │   │
#   │  │ 10.10.1.0/24    │ │ 10.10.3.0/24    │ │                     │   │
#   │  │ ┌─────────────┐ │ │ ┌─────────────┐ │ │ ┌─────────────────┐ │   │
#   │  │ │  AKS Node   │ │ │ │  AKS Node   │ │ │ │  App Gateway    │ │   │
#   │  │ │  (Private)  │ │ │ │  (Private)  │ │ │ │  (Public IP)    │ │   │
#   │  │ └─────────────┘ │ │ └─────────────┘ │ │ └─────────────────┘ │   │
#   │  └─────────────────┘ └─────────────────┘ └─────────────────────┘   │
#   │                              │                     │               │
#   │                          NAT Gateway          Load Balancer        │
#   └──────────────────────────────┼─────────────────────┼───────────────┘
#                                  │                     │
#                              Internet              Internet
# =============================================================================

# -----------------------------------------------------------------------------
# Virtual Network
# -----------------------------------------------------------------------------
resource "azurerm_virtual_network" "vnet" {
  name                = var.vnet_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = [var.vnet_cidr]

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Subnet for AKS Nodes (Primary - spans zones 1 and 3)
# -----------------------------------------------------------------------------
resource "azurerm_subnet" "aks" {
  name                 = "${var.vnet_name}-aks-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.10.0.0/22"]  # Large enough for AKS nodes and pods

  # Required delegation for private clusters
  service_endpoints = [
    "Microsoft.Storage",
    "Microsoft.Sql",
    "Microsoft.KeyVault"
  ]
}

# -----------------------------------------------------------------------------
# Subnet for Application Gateway
# -----------------------------------------------------------------------------
resource "azurerm_subnet" "appgw" {
  name                 = "${var.vnet_name}-appgw-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.appgw_subnet_cidr]
}

# -----------------------------------------------------------------------------
# Subnet for VPN Gateway
# -----------------------------------------------------------------------------
resource "azurerm_subnet" "gateway" {
  name                 = "GatewaySubnet"  # Must be named exactly "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.10.200.0/24"]
}

# -----------------------------------------------------------------------------
# Public IP for NAT Gateway
# -----------------------------------------------------------------------------
resource "azurerm_public_ip" "nat" {
  name                = "${var.vnet_name}-nat-ip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]  # Zone-redundant

  tags = var.tags
}

# -----------------------------------------------------------------------------
# NAT Gateway (for private nodes to access internet)
# -----------------------------------------------------------------------------
resource "azurerm_nat_gateway" "nat" {
  name                    = "${var.vnet_name}-nat-gateway"
  location                = azurerm_resource_group.rg.location
  resource_group_name     = azurerm_resource_group.rg.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  zones                   = ["1"]  # NAT Gateway zone

  tags = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "nat" {
  nat_gateway_id       = azurerm_nat_gateway.nat.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "aks" {
  subnet_id      = azurerm_subnet.aks.id
  nat_gateway_id = azurerm_nat_gateway.nat.id
}

# -----------------------------------------------------------------------------
# Network Security Group for AKS Subnet
# -----------------------------------------------------------------------------
resource "azurerm_network_security_group" "aks" {
  name                = "${var.vnet_name}-aks-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  # Allow inbound from Application Gateway
  security_rule {
    name                       = "AllowAppGateway"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefix      = var.appgw_subnet_cidr
    destination_address_prefix = "*"
  }

  # Allow Azure Load Balancer health probes
  security_rule {
    name                       = "AllowAzureLoadBalancer"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  # Allow VNet internal traffic
  security_rule {
    name                       = "AllowVNetInternal"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  # Allow Consul ports from GCP (via VPN)
  security_rule {
    name                       = "AllowConsulFromGCP"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges    = ["8300", "8301", "8302", "8500", "8501", "8502", "8600"]
    source_address_prefix      = "10.0.0.0/16"  # GCP VPC CIDR
    destination_address_prefix = "*"
  }

  # Deny all other inbound
  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = var.tags
}

resource "azurerm_subnet_network_security_group_association" "aks" {
  subnet_id                 = azurerm_subnet.aks.id
  network_security_group_id = azurerm_network_security_group.aks.id
}

# -----------------------------------------------------------------------------
# Network Security Group for Application Gateway
# -----------------------------------------------------------------------------
resource "azurerm_network_security_group" "appgw" {
  name                = "${var.vnet_name}-appgw-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  # Required: Allow Application Gateway v2 management traffic
  security_rule {
    name                       = "AllowGatewayManager"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "65200-65535"
    source_address_prefix      = "GatewayManager"
    destination_address_prefix = "*"
  }

  # Allow HTTPS from internet
  security_rule {
    name                       = "AllowHTTPS"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  # Allow HTTP for redirect
  security_rule {
    name                       = "AllowHTTP"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  # Allow Azure Load Balancer
  security_rule {
    name                       = "AllowAzureLoadBalancer"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  tags = var.tags
}

resource "azurerm_subnet_network_security_group_association" "appgw" {
  subnet_id                 = azurerm_subnet.appgw.id
  network_security_group_id = azurerm_network_security_group.appgw.id
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "vnet_id" {
  value = azurerm_virtual_network.vnet.id
}

output "vnet_name" {
  value = azurerm_virtual_network.vnet.name
}

output "aks_subnet_id" {
  value = azurerm_subnet.aks.id
}

output "appgw_subnet_id" {
  value = azurerm_subnet.appgw.id
}

output "gateway_subnet_id" {
  value = azurerm_subnet.gateway.id
}