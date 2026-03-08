#!/bin/bash
# =============================================================================
# AKS DEPLOYMENT SCRIPT
# =============================================================================
# This script deploys WordPress on AKS only
#
# USAGE:
#   chmod +x deploy-aks.sh
#   ./deploy-aks.sh [--infra-only | --k8s-only | --destroy]
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

# Options
DEPLOY_INFRA=true
DEPLOY_K8S=true
DESTROY_MODE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --infra-only)
            DEPLOY_K8S=false
            shift
            ;;
        --k8s-only)
            DEPLOY_INFRA=false
            shift
            ;;
        --destroy)
            DESTROY_MODE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

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
    
    command -v terraform >/dev/null 2>&1 || { print_error "terraform is required"; exit 1; }
    command -v az >/dev/null 2>&1 || { print_error "az CLI is required"; exit 1; }
    command -v kubectl >/dev/null 2>&1 || { print_error "kubectl is required"; exit 1; }
    
    # Check Azure authentication
    if ! az account show > /dev/null 2>&1; then
        print_error "Not authenticated to Azure. Run: az login"
        exit 1
    fi
    
    print_success "Prerequisites check passed"
}

# Deploy infrastructure
deploy_infrastructure() {
    print_status "Deploying Azure infrastructure..."
    
    cd "$PROJECT_ROOT/azure"
    
    # Check for terraform.tfvars
    if [ ! -f "terraform.tfvars" ]; then
        print_error "terraform.tfvars not found"
        print_status "Creating from example..."
        if [ -f "terraform.tfvars.example" ]; then
            cp terraform.tfvars.example terraform.tfvars
            print_error "Please edit terraform.tfvars with your values and run again"
            exit 1
        fi
    fi
    
    terraform init -upgrade
    terraform validate
    terraform plan -out=tfplan
    terraform apply tfplan
    
    # Export outputs
    export AKS_CLUSTER_NAME=$(terraform output -raw cluster_name)
    export AZURE_RESOURCE_GROUP=$(terraform output -raw resource_group_name)
    
    # Configure kubectl
    print_status "Configuring kubectl..."
    az aks get-credentials --resource-group "$AZURE_RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" --overwrite-existing
    
    print_success "Azure infrastructure deployed"
    
    cd "$PROJECT_ROOT"
}

# Deploy Kubernetes resources
deploy_kubernetes() {
    print_status "Deploying Kubernetes resources on AKS..."
    
    # Ensure kubectl is configured
    cd "$PROJECT_ROOT/azure"
    if [ -f "terraform.tfstate" ]; then
        local cluster=$(terraform output -raw cluster_name 2>/dev/null)
        local rg=$(terraform output -raw resource_group_name 2>/dev/null)
        az aks get-credentials --resource-group "$rg" --name "$cluster" --overwrite-existing
    fi
    cd "$PROJECT_ROOT"
    
    # Apply manifests
    kubectl apply -f kubernetes/aks/namespace.yaml
    kubectl apply -f kubernetes/aks/secrets.yaml
    kubectl apply -f kubernetes/aks/mysql-statefulset.yaml
    
    print_status "Waiting for MySQL..."
    kubectl wait --for=condition=ready pod/mysql-0 -n wordpress --timeout=300s
    
    kubectl apply -f kubernetes/aks/wordpress-deployment.yaml
    
    print_status "Waiting for WordPress..."
    kubectl wait --for=condition=available deployment/wordpress -n wordpress --timeout=300s
    
    kubectl apply -f kubernetes/aks/ingress.yaml
    kubectl apply -f kubernetes/aks/autoscaler.yaml
    kubectl apply -f kubernetes/aks/logging.yaml
    
    print_success "Kubernetes resources deployed"
    
    # Show status
    echo ""
    echo "=== Deployment Status ==="
    kubectl get pods -n wordpress
    echo ""
    kubectl get svc -n wordpress
    echo ""
    kubectl get ingress -n wordpress
}

# Destroy resources
destroy() {
    print_status "Destroying AKS resources..."
    
    read -p "Are you sure you want to destroy all AKS resources? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        print_status "Cancelled"
        exit 0
    fi
    
    cd "$PROJECT_ROOT/azure"
    
    # Delete Kubernetes resources first
    if terraform output cluster_name &>/dev/null; then
        local cluster=$(terraform output -raw cluster_name)
        local rg=$(terraform output -raw resource_group_name)
        
        az aks get-credentials --resource-group "$rg" --name "$cluster" --overwrite-existing 2>/dev/null || true
        
        kubectl delete namespace wordpress --ignore-not-found=true 2>/dev/null || true
    fi
    
    # Destroy infrastructure
    terraform destroy -auto-approve
    
    print_success "AKS resources destroyed"
    
    cd "$PROJECT_ROOT"
}

# Main
main() {
    echo -e "${BLUE}=== AKS Deployment Script ===${NC}"
    
    if $DESTROY_MODE; then
        destroy
        exit 0
    fi
    
    check_prerequisites
    
    if $DEPLOY_INFRA; then
        deploy_infrastructure
    fi
    
    if $DEPLOY_K8S; then
        deploy_kubernetes
    fi
    
    print_success "AKS deployment completed!"
    
    echo ""
    echo "Next steps:"
    echo "1. Update DNS to point to the Application Gateway IP"
    echo "2. Configure SSL certificate in Application Gateway"
    echo "3. Access WordPress at your domain"
}

main