# =============================================================================
# AZURE OUTPUTS
# =============================================================================

output "resource_group_name" {
  value       = azurerm_resource_group.rg.name
  description = "Resource group name"
}

output "cluster_name" {
  value       = azurerm_kubernetes_cluster.aks.name
  description = "AKS cluster name"
}

output "cluster_id" {
  value       = azurerm_kubernetes_cluster.aks.id
  description = "AKS cluster ID"
}

output "kube_config" {
  value       = azurerm_kubernetes_cluster.aks.kube_config_raw
  description = "Kubernetes config file contents"
  sensitive   = true
}

output "cluster_fqdn" {
  value       = azurerm_kubernetes_cluster.aks.fqdn
  description = "AKS cluster FQDN"
}

output "appgw_public_ip" {
  value       = azurerm_public_ip.appgw.ip_address
  description = "Application Gateway public IP"
}

output "log_analytics_workspace_id" {
  value       = azurerm_log_analytics_workspace.law.id
  description = "Log Analytics Workspace ID"
}

output "configure_kubectl" {
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.rg.name} --name ${azurerm_kubernetes_cluster.aks.name}"
  description = "Run this command to configure kubectl"
}

output "azure_vpn_gateway_ip" {
  value       = azurerm_public_ip.vpn.ip_address
  description = "Azure VPN Gateway public IP (configure this in GCP)"
}

output "consul_config" {
  value = {
    datacenter    = "azure-${var.location}"
    network_cidr  = var.vnet_cidr
  }
  description = "Configuration for Consul in AKS"
}