#!/bin/bash
# =============================================================================
# MASTER DEPLOYMENT SCRIPT
# =============================================================================
# This script deploys the entire WordPress infrastructure on GKE and AKS
#
# PREREQUISITES:
#   1. terraform >= 1.0.0
#   2. gcloud CLI (authenticated)
#   3. az CLI (authenticated)
#   4. kubectl
#   5. helm >= 3.0.0
#
# USAGE:
#   chmod +x deploy-all.sh
#   ./deploy-all.sh
# =============================================================================

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  WordPress Multi-Cloud Deployment${NC}"
echo -e "${GREEN}============================================${NC}"

# Function to print status
print_status() {
    echo -e "${YELLOW}[STATUS]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    command -v terraform >/dev/null 2>&1 || { print_error "terraform is required but not installed."; exit 1; }
    command -v gcloud >/dev/null 2>&1 || { print_error "gcloud is required but not installed."; exit 1; }
    command -v az >/dev/null 2>&1 || { print_error "az CLI is required but not installed."; exit 1; }
    command -v kubectl >/dev/null 2>&1 || { print_error "kubectl is required but not installed."; exit 1; }
    command -v helm >/dev/null 2>&1 || { print_error "helm is required but not installed."; exit 1; }
    
    print_success "All prerequisites are installed"
}

# Deploy GCP infrastructure
deploy_gcp() {
    print_status "Deploying GCP infrastructure..."
    
    cd "$PROJECT_ROOT/gcp"
    
    # Initialize Terraform
    terraform init
    
    # Plan deployment
    terraform plan -out=tfplan
    
    # Apply deployment
    terraform apply tfplan
    
    # Get outputs
    export GCP_VPN_IP=$(terraform output -raw vpn_gateway_ip)
    export GKE_CLUSTER_NAME=$(terraform output -raw cluster_name)
    
    print_success "GCP infrastructure deployed"
    print_status "GCP VPN Gateway IP: $GCP_VPN_IP"
    
    # Configure kubectl for GKE
    print_status "Configuring kubectl for GKE..."
    $(terraform output -raw configure_kubectl)
    
    cd "$PROJECT_ROOT"
}

# Deploy Azure infrastructure
deploy_azure() {
    print_status "Deploying Azure infrastructure..."
    
    cd "$PROJECT_ROOT/azure"
    
    # Update terraform.tfvars with GCP VPN IP
    if [ -n "$GCP_VPN_IP" ]; then
        sed -i "s/gcp_vpn_gateway_ip = \"\"/gcp_vpn_gateway_ip = \"$GCP_VPN_IP\"/" terraform.tfvars
    fi
    
    # Initialize Terraform
    terraform init
    
    # Plan deployment
    terraform plan -out=tfplan
    
    # Apply deployment
    terraform apply tfplan
    
    # Get outputs
    export AZURE_VPN_IP=$(terraform output -raw vpn_gateway_ip)
    export AKS_CLUSTER_NAME=$(terraform output -raw cluster_name)
    
    print_success "Azure infrastructure deployed"
    print_status "Azure VPN Gateway IP: $AZURE_VPN_IP"
    
    cd "$PROJECT_ROOT"
}

# Update GCP with Azure VPN IP
update_gcp_vpn() {
    print_status "Updating GCP VPN with Azure IP..."
    
    cd "$PROJECT_ROOT/gcp"
    
    # Update terraform.tfvars with Azure VPN IP
    if [ -n "$AZURE_VPN_IP" ]; then
        sed -i "s/azure_vpn_gateway_ip = \"\"/azure_vpn_gateway_ip = \"$AZURE_VPN_IP\"/" terraform.tfvars
        
        terraform plan -out=tfplan
        terraform apply tfplan
    fi
    
    print_success "GCP VPN configuration updated"
    
    cd "$PROJECT_ROOT"
}

# Deploy Kubernetes resources on GKE
deploy_gke_k8s() {
    print_status "Deploying Kubernetes resources on GKE..."
    
    # Configure kubectl for GKE
    cd "$PROJECT_ROOT/gcp"
    $(terraform output -raw configure_kubectl)
    cd "$PROJECT_ROOT"
    
    # Apply Kubernetes manifests
    kubectl apply -f kubernetes/gke/namespace.yaml
    kubectl apply -f kubernetes/gke/secrets.yaml
    kubectl apply -f kubernetes/gke/persistent-volumes.yaml
    kubectl apply -f kubernetes/gke/mysql-statefulset.yaml
    
    # Wait for MySQL to be ready
    print_status "Waiting for MySQL to be ready..."
    kubectl wait --for=condition=ready pod/mysql-0 -n wordpress --timeout=300s
    
    kubectl apply -f kubernetes/gke/wordpress-deployment.yaml
    kubectl apply -f kubernetes/gke/managed-certificate.yaml
    kubectl apply -f kubernetes/gke/ingress.yaml
    kubectl apply -f kubernetes/gke/autoscaler.yaml
    kubectl apply -f kubernetes/gke/logging.yaml
    
    print_success "GKE Kubernetes resources deployed"
}

# Deploy Kubernetes resources on AKS
deploy_aks_k8s() {
    print_status "Deploying Kubernetes resources on AKS..."
    
    # Configure kubectl for AKS
    cd "$PROJECT_ROOT/azure"
    $(terraform output -raw configure_kubectl)
    cd "$PROJECT_ROOT"
    
    # Apply Kubernetes manifests
    kubectl apply -f kubernetes/aks/namespace.yaml
    kubectl apply -f kubernetes/aks/secrets.yaml
    kubectl apply -f kubernetes/aks/mysql-statefulset.yaml
    
    # Wait for MySQL to be ready
    print_status "Waiting for MySQL to be ready..."
    kubectl wait --for=condition=ready pod/mysql-0 -n wordpress --timeout=300s
    
    kubectl apply -f kubernetes/aks/wordpress-deployment.yaml
    kubectl apply -f kubernetes/aks/ingress.yaml
    kubectl apply -f kubernetes/aks/autoscaler.yaml
    kubectl apply -f kubernetes/aks/logging.yaml
    
    print_success "AKS Kubernetes resources deployed"
}

# Deploy Consul for cross-cloud communication
deploy_consul() {
    print_status "Deploying Consul service mesh..."
    
    # Add Consul Helm repo
    helm repo add hashicorp https://helm.releases.hashicorp.com
    helm repo update
    
    # Deploy Consul on GKE (primary)
    print_status "Deploying Consul on GKE..."
    cd "$PROJECT_ROOT/gcp"
    $(terraform output -raw configure_kubectl)
    cd "$PROJECT_ROOT"
    
    kubectl create namespace consul --dry-run=client -o yaml | kubectl apply -f -
    helm upgrade --install consul hashicorp/consul \
        -f consul/gke/consul-values.yaml \
        -n consul \
        --wait
    
    # Get federation secret
    kubectl get secret consul-federation -n consul -o yaml > /tmp/consul-federation.yaml
    
    # Deploy Consul on AKS (secondary)
    print_status "Deploying Consul on AKS..."
    cd "$PROJECT_ROOT/azure"
    $(terraform output -raw configure_kubectl)
    cd "$PROJECT_ROOT"
    
    kubectl create namespace consul --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f /tmp/consul-federation.yaml -n consul
    helm upgrade --install consul hash