#!/bin/bash
# =============================================================================
# CONSUL SETUP SCRIPT
# =============================================================================
# This script sets up Consul service mesh for cross-cloud communication
#
# PREREQUISITES:
#   - GKE and AKS clusters must be deployed
#   - VPN tunnel between GCP and Azure must be established
#   - kubectl and helm must be installed
#
# USAGE:
#   chmod +x setup-consul.sh
#   ./setup-consul.sh [--destroy]
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

DESTROY_MODE=false

# Parse arguments
if [ "$1" == "--destroy" ]; then
    DESTROY_MODE=true
fi

print_status() {
    echo -e "${YELLOW}[STATUS]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get GKE credentials
configure_gke() {
    cd "$PROJECT_ROOT/gcp"
    local cluster=$(terraform output -raw cluster_name 2>/dev/null)
    local region=$(terraform output -raw cluster_location 2>/dev/null)
    local project=$(grep 'project_id' terraform.tfvars | cut -d'"' -f2)
    gcloud container clusters get-credentials "$cluster" --region "$region" --project "$project"
    cd "$PROJECT_ROOT"
}

# Get AKS credentials
configure_aks() {
    cd "$PROJECT_ROOT/azure"
    local cluster=$(terraform output -raw cluster_name 2>/dev/null)
    local rg=$(terraform output -raw resource_group_name 2>/dev/null)
    az aks get-credentials --resource-group "$rg" --name "$cluster" --overwrite-existing
    cd "$PROJECT_ROOT"
}

# Deploy Consul on GKE
deploy_consul_gke() {
    print_status "Deploying Consul on GKE (primary datacenter)..."
    
    configure_gke
    
    # Add Helm repo
    helm repo add hashicorp https://helm.releases.hashicorp.com
    helm repo update
    
    # Create namespace
    kubectl create namespace consul --dry-run=client -o yaml | kubectl apply -f -
    
    # Install Consul
    helm upgrade --install consul hashicorp/consul \
        -f "$PROJECT_ROOT/consul/gke/consul-values.yaml" \
        -n consul \
        --wait \
        --timeout 10m
    
    print_success "Consul deployed on GKE"
    
    # Wait for federation secret
    print_status "Waiting for federation secret to be created..."
    for i in {1..30}; do
        if kubectl get secret consul-federation -n consul &>/dev/null; then
            print_success "Federation secret created"
            break
        fi
        echo "Waiting... ($i/30)"
        sleep 10
    done
    
    # Export federation secret
    kubectl get secret consul-federation -n consul -o yaml > /tmp/consul-federation.yaml
    
    # Get mesh gateway IP
    print_status "Waiting for mesh gateway external IP..."
    local mesh_ip=""
    for i in {1..30}; do
        mesh_ip=$(kubectl get svc consul-mesh-gateway -n consul -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        if [ -n "$mesh_ip" ]; then
            print_success "GKE Mesh Gateway IP: $mesh_ip"
            export GKE_MESH_GATEWAY_IP="$mesh_ip"
            break
        fi
        echo "Waiting for IP... ($i/30)"
        sleep 10
    done
}

# Deploy Consul on AKS
deploy_consul_aks() {
    print_status "Deploying Consul on AKS (secondary datacenter)..."
    
    configure_aks
    
    # Create namespace
    kubectl create namespace consul --dry-run=client -o yaml | kubectl apply -f -
    
    # Apply federation secret from GKE
    if [ -f /tmp/consul-federation.yaml ]; then
        kubectl apply -f /tmp/consul-federation.yaml -n consul
        print_success "Federation secret applied"
    else
        print_error "Federation secret not found!"
        exit 1
    fi
    
    # Update values with GKE mesh gateway IP
    local values_file="$PROJECT_ROOT/consul/aks/consul-values.yaml"
    if [ -n "$GKE_MESH_GATEWAY_IP" ]; then
        sed -i.bak "s/<GCP_MESH_GATEWAY_IP>/$GKE_MESH_GATEWAY_IP/g" "$values_file"
    fi
    
    # Install Consul
    helm upgrade --install consul hashicorp/consul \
        -f "$values_file" \
        -n consul \
        --wait \
        --timeout 10m
    
    print_success "Consul deployed on AKS"
    
    # Restore values file
    if [ -f "${values_file}.bak" ]; then
        mv "${values_file}.bak" "$values_file"
    fi
}

# Configure service intentions
configure_intentions() {
    print_status "Configuring Consul service intentions..."
    
    # Apply mesh gateway configs on GKE
    configure_gke
    kubectl apply -f "$PROJECT_ROOT/consul/gke/mesh-gateway.yaml" -n wordpress 2>/dev/null || true
    
    # Apply mesh gateway configs on AKS
    configure_aks
    kubectl apply -f "$PROJECT_ROOT/consul/aks/mesh-gateway.yaml" -n wordpress 2>/dev/null || true
    
    print_success "Service intentions configured"
}

# Verify federation
verify_federation() {
    print_status "Verifying Consul federation..."
    
    # Check GKE
    configure_gke
    echo "=== GKE Consul Status ==="
    kubectl exec -n consul consul-server-0 -- consul members -wan 2>/dev/null || echo "Unable to get WAN members"
    
    # Check AKS
    configure_aks
    echo ""
    echo "=== AKS Consul Status ==="
    kubectl exec -n consul consul-server-0 -- consul members -wan 2>/dev/null || echo "Unable to get WAN members"
}

# Destroy Consul
destroy_consul() {
    print_status "Destroying Consul..."
    
    read -p "Are you sure you want to destroy Consul? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        print_status "Cancelled"
        exit 0
    fi
    
    # Remove from AKS
    configure_aks
    helm uninstall consul -n consul 2>/dev/null || true
    kubectl delete namespace consul --ignore-not-found=true
    
    # Remove from GKE
    configure_gke
    helm uninstall consul -n consul 2>/dev/null || true
    kubectl delete namespace consul --ignore-not-found=true
    
    # Cleanup
    rm -f /tmp/consul-federation.yaml
    
    print_success "Consul destroyed"
}

# Main
main() {
    echo -e "${BLUE}=== Consul Setup Script ===${NC}"
    
    if $DESTROY_MODE; then
        destroy_consul
        exit 0
    fi
    
    # Check prerequisites
    command -v helm >/dev/null 2>&1 || { print_error "helm is required"; exit 1; }
    command -v kubectl >/dev/null 2>&1 || { print_error "kubectl is required"; exit 1; }
    
    deploy_consul_gke
    deploy_consul_aks
    configure_intentions
    verify_federation
    
    print_success "Consul service mesh setup completed!"
    
    echo ""
    echo "Consul is now configured for cross-cloud communication."
    echo "Services can communicate across GKE and AKS through the mesh gateways."
}

main