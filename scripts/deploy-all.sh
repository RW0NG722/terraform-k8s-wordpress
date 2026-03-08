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
#   ./deploy-all.sh [OPTIONS]
#
# OPTIONS:
#   --gcp-only      Deploy only GCP resources
#   --azure-only    Deploy only Azure resources
#   --k8s-only      Deploy only Kubernetes manifests (skip Terraform)
#   --consul-only   Deploy only Consul
#   --destroy       Destroy all resources
#   --help          Show this help message
# =============================================================================

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Default options
DEPLOY_GCP=true
DEPLOY_AZURE=true
DEPLOY_K8S=true
DEPLOY_CONSUL=true
DESTROY_MODE=false

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --gcp-only)
                DEPLOY_AZURE=false
                DEPLOY_CONSUL=false
                shift
                ;;
            --azure-only)
                DEPLOY_GCP=false
                DEPLOY_CONSUL=false
                shift
                ;;
            --k8s-only)
                DEPLOY_GCP=false
                DEPLOY_AZURE=false
                shift
                ;;
            --consul-only)
                DEPLOY_GCP=false
                DEPLOY_AZURE=false
                DEPLOY_K8S=false
                shift
                ;;
            --destroy)
                DESTROY_MODE=true
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --gcp-only      Deploy only GCP resources"
    echo "  --azure-only    Deploy only Azure resources"
    echo "  --k8s-only      Deploy only Kubernetes manifests (skip Terraform)"
    echo "  --consul-only   Deploy only Consul"
    echo "  --destroy       Destroy all resources"
    echo "  --help          Show this help message"
}

# Function to print status messages
print_header() {
    echo ""
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""
}

print_status() {
    echo -e "${YELLOW}[STATUS]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"
    
    local missing_tools=()
    
    if ! command -v terraform &> /dev/null; then
        missing_tools+=("terraform")
    else
        print_success "terraform $(terraform version -json | jq -r '.terraform_version') found"
    fi
    
    if ! command -v gcloud &> /dev/null; then
        missing_tools+=("gcloud")
    else
        print_success "gcloud $(gcloud version 2>/dev/null | head -1 | awk '{print $4}') found"
    fi
    
    if ! command -v az &> /dev/null; then
        missing_tools+=("az")
    else
        print_success "az $(az version 2>/dev/null | jq -r '.["azure-cli"]') found"
    fi
    
    if ! command -v kubectl &> /dev/null; then
        missing_tools+=("kubectl")
    else
        print_success "kubectl $(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion') found"
    fi
    
    if ! command -v helm &> /dev/null; then
        missing_tools+=("helm")
    else
        print_success "helm $(helm version --short 2>/dev/null) found"
    fi
    
    if ! command -v jq &> /dev/null; then
        missing_tools+=("jq")
    else
        print_success "jq $(jq --version) found"
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        echo ""
        echo "Please install the missing tools:"
        echo "  - terraform: https://www.terraform.io/downloads"
        echo "  - gcloud: https://cloud.google.com/sdk/docs/install"
        echo "  - az: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        echo "  - kubectl: https://kubernetes.io/docs/tasks/tools/"
        echo "  - helm: https://helm.sh/docs/intro/install/"
        echo "  - jq: https://stedolan.github.io/jq/download/"
        exit 1
    fi
    
    print_success "All prerequisites are installed"
}

# Check authentication
check_authentication() {
    print_header "Checking Authentication"
    
    # Check GCP authentication
    if $DEPLOY_GCP; then
        print_status "Checking GCP authentication..."
        if gcloud auth list --filter=status:ACTIVE --format="value(account)" | head -1 > /dev/null 2>&1; then
            local gcp_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" | head -1)
            print_success "GCP authenticated as: $gcp_account"
        else
            print_error "Not authenticated to GCP. Please run: gcloud auth login"
            exit 1
        fi
    fi
    
    # Check Azure authentication
    if $DEPLOY_AZURE; then
        print_status "Checking Azure authentication..."
        if az account show > /dev/null 2>&1; then
            local azure_account=$(az account show --query user.name -o tsv)
            print_success "Azure authenticated as: $azure_account"
        else
            print_error "Not authenticated to Azure. Please run: az login"
            exit 1
        fi
    fi
}

# Check if terraform.tfvars exists
check_tfvars() {
    print_header "Checking Configuration Files"
    
    if $DEPLOY_GCP; then
        if [ ! -f "$PROJECT_ROOT/gcp/terraform.tfvars" ]; then
            print_error "GCP terraform.tfvars not found"
            print_info "Please copy terraform.tfvars.example to terraform.tfvars and fill in your values"
            print_info "cp $PROJECT_ROOT/gcp/terraform.tfvars.example $PROJECT_ROOT/gcp/terraform.tfvars"
            exit 1
        fi
        print_success "GCP terraform.tfvars found"
    fi
    
    if $DEPLOY_AZURE; then
        if [ ! -f "$PROJECT_ROOT/azure/terraform.tfvars" ]; then
            print_error "Azure terraform.tfvars not found"
            print_info "Please copy terraform.tfvars.example to terraform.tfvars and fill in your values"
            print_info "cp $PROJECT_ROOT/azure/terraform.tfvars.example $PROJECT_ROOT/azure/terraform.tfvars"
            exit 1
        fi
        print_success "Azure terraform.tfvars found"
    fi
}

# Deploy GCP infrastructure
deploy_gcp_infra() {
    print_header "Deploying GCP Infrastructure"
    
    cd "$PROJECT_ROOT/gcp"
    
    print_status "Initializing Terraform..."
    terraform init -upgrade
    
    print_status "Validating Terraform configuration..."
    terraform validate
    
    print_status "Planning deployment..."
    terraform plan -out=tfplan
    
    print_status "Applying deployment (this may take 10-15 minutes)..."
    terraform apply tfplan
    
    # Get outputs and export them
    export GCP_VPN_IP=$(terraform output -raw vpn_gateway_ip 2>/dev/null || echo "")
    export GKE_CLUSTER_NAME=$(terraform output -raw cluster_name)
    export GKE_REGION=$(terraform output -raw cluster_location)
    export GCP_PROJECT_ID=$(terraform output -raw project_id 2>/dev/null || grep 'project_id' terraform.tfvars | cut -d'"' -f2)
    export GKE_INGRESS_IP=$(terraform output -raw ingress_ip 2>/dev/null || echo "pending")
    
    print_success "GCP infrastructure deployed successfully!"
    echo ""
    print_info "GKE Cluster: $GKE_CLUSTER_NAME"
    print_info "GCP Region: $GKE_REGION"
    print_info "GCP VPN Gateway IP: $GCP_VPN_IP"
    print_info "Ingress Static IP: $GKE_INGRESS_IP"
    
    # Configure kubectl
    print_status "Configuring kubectl for GKE..."
    gcloud container clusters get-credentials "$GKE_CLUSTER_NAME" --region "$GKE_REGION" --project "$GCP_PROJECT_ID"
    
    # Verify connection
    if kubectl cluster-info > /dev/null 2>&1; then
        print_success "kubectl configured for GKE"
    else
        print_error "Failed to configure kubectl for GKE"
        exit 1
    fi
    
    cd "$PROJECT_ROOT"
}

# Deploy Azure infrastructure
deploy_azure_infra() {
    print_header "Deploying Azure Infrastructure"
    
    cd "$PROJECT_ROOT/azure"
    
    # Update terraform.tfvars with GCP VPN IP if available
    if [ -n "$GCP_VPN_IP" ] && [ "$GCP_VPN_IP" != "" ]; then
        print_status "Updating Azure config with GCP VPN IP: $GCP_VPN_IP"
        if grep -q 'gcp_vpn_gateway_ip' terraform.tfvars; then
            sed -i.bak "s/gcp_vpn_gateway_ip = \".*\"/gcp_vpn_gateway_ip = \"$GCP_VPN_IP\"/" terraform.tfvars
        else
            echo "gcp_vpn_gateway_ip = \"$GCP_VPN_IP\"" >> terraform.tfvars
        fi
    fi
    
    print_status "Initializing Terraform..."
    terraform init -upgrade
    
    print_status "Validating Terraform configuration..."
    terraform validate
    
    print_status "Planning deployment..."
    terraform plan -out=tfplan
    
    print_status "Applying deployment (this may take 15-20 minutes)..."
    terraform apply tfplan
    
    # Get outputs
    export AZURE_VPN_IP=$(terraform output -raw vpn_gateway_ip 2>/dev/null || echo "")
    export AKS_CLUSTER_NAME=$(terraform output -raw cluster_name)
    export AZURE_RESOURCE_GROUP=$(terraform output -raw resource_group_name)
    export AKS_APPGW_IP=$(terraform output -raw appgw_public_ip 2>/dev/null || echo "pending")
    
    print_success "Azure infrastructure deployed successfully!"
    echo ""
    print_info "AKS Cluster: $AKS_CLUSTER_NAME"
    print_info "Resource Group: $AZURE_RESOURCE_GROUP"
    print_info "Azure VPN Gateway IP: $AZURE_VPN_IP"
    print_info "Application Gateway IP: $AKS_APPGW_IP"
    
    # Configure kubectl
    print_status "Configuring kubectl for AKS..."
    az aks get-credentials --resource-group "$AZURE_RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" --overwrite-existing
    
    # Verify connection
    if kubectl cluster-info > /dev/null 2>&1; then
        print_success "kubectl configured for AKS"
    else
        print_error "Failed to configure kubectl for AKS"
        exit 1
    fi
    
    cd "$PROJECT_ROOT"
}

# Update GCP with Azure VPN IP
update_gcp_vpn() {
    if [ -n "$AZURE_VPN_IP" ] && [ "$AZURE_VPN_IP" != "" ]; then
        print_header "Updating GCP VPN Configuration"
        
        cd "$PROJECT_ROOT/gcp"
        
        print_status "Adding Azure VPN IP to GCP configuration..."
        if grep -q 'azure_vpn_gateway_ip' terraform.tfvars; then
            sed -i.bak "s/azure_vpn_gateway_ip = \".*\"/azure_vpn_gateway_ip = \"$AZURE_VPN_IP\"/" terraform.tfvars
        else
            echo "azure_vpn_gateway_ip = \"$AZURE_VPN_IP\"" >> terraform.tfvars
        fi
        
        terraform plan -out=tfplan
        terraform apply tfplan
        
        print_success "GCP VPN configuration updated with Azure IP: $AZURE_VPN_IP"
        
        cd "$PROJECT_ROOT"
    fi
}

# Deploy Kubernetes resources on GKE
deploy_gke_k8s() {
    print_header "Deploying Kubernetes Resources on GKE"
    
    # Configure kubectl for GKE
    cd "$PROJECT_ROOT/gcp"
    local gke_cluster=$(terraform output -raw cluster_name 2>/dev/null)
    local gke_region=$(terraform output -raw cluster_location 2>/dev/null)
    local gcp_project=$(grep 'project_id' terraform.tfvars | cut -d'"' -f2)
    
    print_status "Switching kubectl context to GKE..."
    gcloud container clusters get-credentials "$gke_cluster" --region "$gke_region" --project "$gcp_project"
    cd "$PROJECT_ROOT"
    
    # Verify we're connected to the right cluster
    local current_context=$(kubectl config current-context)
    print_info "Current kubectl context: $current_context"
    
    # Apply manifests in order
    print_status "Creating namespace..."
    kubectl apply -f kubernetes/gke/namespace.yaml
    
    print_status "Creating secrets..."
    kubectl apply -f kubernetes/gke/secrets.yaml
    
    print_status "Creating storage classes and PVCs..."
    kubectl apply -f kubernetes/gke/persistent-volumes.yaml
    
    print_status "Deploying MySQL StatefulSet..."
    kubectl apply -f kubernetes/gke/mysql-statefulset.yaml
    
    print_status "Waiting for MySQL to be ready (this may take 2-3 minutes)..."
    kubectl wait --for=condition=ready pod/mysql-0 -n wordpress --timeout=300s || {
        print_error "MySQL pod failed to become ready"
        kubectl describe pod mysql-0 -n wordpress
        kubectl logs mysql-0 -n wordpress --tail=50
        exit 1
    }
    print_success "MySQL is ready"
    
    print_status "Deploying WordPress..."
    kubectl apply -f kubernetes/gke/wordpress-deployment.yaml
    
    print_status "Waiting for WordPress to be ready..."
    kubectl wait --for=condition=available deployment/wordpress -n wordpress --timeout=300s || {
        print_error "WordPress deployment failed to become ready"
        kubectl describe deployment wordpress -n wordpress
        exit 1
    }
    print_success "WordPress is ready"
    
    print_status "Creating managed certificate..."
    kubectl apply -f kubernetes/gke/managed-certificate.yaml
    
    print_status "Creating ingress..."
    kubectl apply -f kubernetes/gke/ingress.yaml
    
    print_status "Applying autoscaler configuration..."
    kubectl apply -f kubernetes/gke/autoscaler.yaml
    
    print_status "Applying logging configuration..."
    kubectl apply -f kubernetes/gke/logging.yaml
    
    print_success "GKE Kubernetes resources deployed successfully!"
    
    # Show status
    echo ""
    print_info "Deployment Status:"
    kubectl get pods -n wordpress
    echo ""
    kubectl get svc -n wordpress
    echo ""
    kubectl get ingress -n wordpress
}

# Deploy Kubernetes resources on AKS
deploy_aks_k8s() {
    print_header "Deploying Kubernetes Resources on AKS"
    
    # Configure kubectl for AKS
    cd "$PROJECT_ROOT/azure"
    local aks_cluster=$(terraform output -raw cluster_name 2>/dev/null)
    local resource_group=$(terraform output -raw resource_group_name 2>/dev/null)
    
    print_status "Switching kubectl context to AKS..."
    az aks get-credentials --resource-group "$resource_group" --name "$aks_cluster" --overwrite-existing
    cd "$PROJECT_ROOT"
    
    # Verify context
    local current_context=$(kubectl config current-context)
    print_info "Current kubectl context: $current_context"
    
    # Apply manifests in order
    print_status "Creating namespace..."
    kubectl apply -f kubernetes/aks/namespace.yaml
    
    print_status "Creating secrets..."
    kubectl apply -f kubernetes/aks/secrets.yaml
    
    print_status "Deploying MySQL StatefulSet..."
    kubectl apply -f kubernetes/aks/mysql-statefulset.yaml
    
    print_status "Waiting for MySQL to be ready (this may take 2-3 minutes)..."
    kubectl wait --for=condition=ready pod/mysql-0 -n wordpress --timeout=300s || {
        print_error "MySQL pod failed to become ready"
        kubectl describe pod mysql-0 -n wordpress
        kubectl logs mysql-0 -n wordpress --tail=50
        exit 1
    }
    print_success "MySQL is ready"
    
    print_status "Deploying WordPress..."
    kubectl apply -f kubernetes/aks/wordpress-deployment.yaml
    
    print_status "Waiting for WordPress to be ready..."
    kubectl wait --for=condition=available deployment/wordpress -n wordpress --timeout=300s || {
        print_error "WordPress deployment failed to become ready"
        kubectl describe deployment wordpress -n wordpress
        exit 1
    }
    print_success "WordPress is ready"
    
    print_status "Creating ingress..."
    kubectl apply -f kubernetes/aks/ingress.yaml
    
    print_status "Applying autoscaler configuration..."
    kubectl apply -f kubernetes/aks/autoscaler.yaml
    
    print_status "Applying logging configuration..."
    kubectl apply -f kubernetes/aks/logging.yaml
    
    print_success "AKS Kubernetes resources deployed successfully!"
    
    # Show status
    echo ""
    print_info "Deployment Status:"
    kubectl get pods -n wordpress
    echo ""
    kubectl get svc -n wordpress
    echo ""
    kubectl get ingress -n wordpress
}

# Deploy Consul
deploy_consul() {
    print_header "Deploying Consul Service Mesh"
    
    # Add Helm repo
    print_status "Adding HashiCorp Helm repository..."
    helm repo add hashicorp https://helm.releases.hashicorp.com
    helm repo update
    
    # Deploy on GKE first (primary datacenter)
    print_status "Deploying Consul on GKE (primary datacenter)..."
    
    cd "$PROJECT_ROOT/gcp"
    local gke_cluster=$(terraform output -raw cluster_name 2>/dev/null)
    local gke_region=$(terraform output -raw cluster_location 2>/dev/null)
    local gcp_project=$(grep 'project_id' terraform.tfvars | cut -d'"' -f2)
    gcloud container clusters get-credentials "$gke_cluster" --region "$gke_region" --project "$gcp_project"
    cd "$PROJECT_ROOT"
    
    kubectl create namespace consul --dry-run=client -o yaml | kubectl apply -f -
    
    helm upgrade --install consul hashicorp/consul \
        -f consul/gke/consul-values.yaml \
        -n consul \
        --wait \
        --timeout 10m
    
    print_success "Consul deployed on GKE"
    
    # Wait for federation secret to be created
    print_status "Waiting for federation secret..."
    sleep 30
    
    # Get federation secret
    kubectl get secret consul-federation -n consul -o yaml > /tmp/consul-federation.yaml 2>/dev/null || {
        print_error "Federation secret not found. Consul may not be fully initialized."
        print_info "You may need to manually export the federation secret later."
    }
    
    # Get mesh gateway IP
    local gke_mesh_gateway_ip=""
    for i in {1..30}; do
        gke_mesh_gateway_ip=$(kubectl get svc consul-mesh-gateway -n consul -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        if [ -n "$gke_mesh_gateway_ip" ]; then
            break
        fi
        print_status "Waiting for GKE mesh gateway IP... ($i/30)"
        sleep 10
    done
    
    if [ -n "$gke_mesh_gateway_ip" ]; then
        print_success "GKE Mesh Gateway IP: $gke_mesh_gateway_ip"
    fi
    
    # Deploy on AKS (secondary datacenter)
    print_status "Deploying Consul on AKS (secondary datacenter)..."
    
    cd "$PROJECT_ROOT/azure"
    local aks_cluster=$(terraform output -raw cluster_name 2>/dev/null)
    local resource_group=$(terraform output -raw resource_group_name 2>/dev/null)
    az aks get-credentials --resource-group "$resource_group" --name "$aks_cluster" --overwrite-existing
    cd "$PROJECT_ROOT"
    
    kubectl create namespace consul --dry-run=client -o yaml | kubectl apply -f -
    
    # Apply federation secret
    if [ -f /tmp/consul-federation.yaml ]; then
        kubectl apply -f /tmp/consul-federation.yaml -n consul
    fi
    
    # Update Consul values with GKE mesh gateway IP
    if [ -n "$gke_mesh_gateway_ip" ]; then
        sed -i.bak "s/<GCP_MESH_GATEWAY_IP>/$gke_mesh_gateway_ip/g" consul/aks/consul-values.yaml
    fi
    
    helm upgrade --install consul hashicorp/consul \
        -f consul/aks/consul-values.yaml \
        -n consul \
        --wait \
        --timeout 10m
    
    print_success "Consul deployed on AKS"
    
    # Deploy mesh gateway configurations
    print_status "Applying mesh gateway configurations..."
    
    # GKE
    cd "$PROJECT_ROOT/gcp"
    gcloud container clusters get-credentials "$gke_cluster" --region "$gke_region" --project "$gcp_project"
    cd "$PROJECT_ROOT"
    kubectl apply -f consul/gke/mesh-gateway.yaml -n wordpress 2>/dev/null || true
    
    # AKS
    cd "$PROJECT_ROOT/azure"
    az aks get-credentials --resource-group "$resource_group" --name "$aks_cluster" --overwrite-existing
    cd "$PROJECT_ROOT"
    kubectl apply -f consul/aks/mesh-gateway.yaml -n wordpress 2>/dev/null || true
    
    print_success "Consul service mesh deployed successfully!"
    
    # Clean up
    rm -f /tmp/consul-federation.yaml
}

# Destroy all resources
destroy_all() {
    print_header "Destroying All Resources"
    
    echo -e "${RED}WARNING: This will destroy all resources in both GCP and Azure!${NC}"
    read -p "Are you sure you want to continue? (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_info "Destruction cancelled"
        exit 0
    fi
    
    # Destroy Consul first
    print_status "Removing Consul..."
    
    cd "$PROJECT_ROOT/gcp"
    if terraform output cluster_name &>/dev/null; then
        local gke_cluster=$(terraform output -raw cluster_name)
        local gke_region=$(terraform output -raw cluster_location)
        local gcp_project=$(grep 'project_id' terraform.tfvars | cut -d'"' -f2)
        gcloud container clusters get-credentials "$gke_cluster" --region "$gke_region" --project "$gcp_project" 2>/dev/null || true
        helm uninstall consul -n consul 2>/dev/null || true
        kubectl delete namespace consul 2>/dev/null || true
    fi
    cd "$PROJECT_ROOT"
    
    cd "$PROJECT_ROOT/azure"
    if terraform output cluster_name &>/dev/null; then
        local aks_cluster=$(terraform output -raw cluster_name)
        local resource_group=$(terraform output -raw resource_group_name)
        az aks get-credentials --resource-group "$resource_group" --name "$aks_cluster" --overwrite-existing 2>/dev/null || true
        helm uninstall consul -n consul 2>/dev/null || true
        kubectl delete namespace consul 2>/dev/null || true
    fi
    cd "$PROJECT_ROOT"
    
    # Destroy Azure infrastructure
    print_status "Destroying Azure infrastructure..."
    cd "$PROJECT_ROOT/azure"
    terraform destroy -auto-approve || true
    cd "$PROJECT_ROOT"
    
    # Destroy GCP infrastructure
    print_status "Destroying GCP infrastructure..."
    cd "$PROJECT_ROOT/gcp"
    terraform destroy -auto-approve || true
    cd "$PROJECT_ROOT"
    
    print_success "All resources have been destroyed"
}

# Print deployment summary
print_summary() {
    print_header "Deployment Summary"
    
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                    DEPLOYMENT COMPLETED                          ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    
    if $DEPLOY_GCP && [ -n "$GKE_CLUSTER_NAME" ]; then
        echo "║ GKE Cluster: $GKE_CLUSTER_NAME"
        echo "║ GCP Region: $GKE_REGION"
        echo "║ GKE Ingress IP: $GKE_INGRESS_IP"
        echo "║ GCP VPN Gateway: $GCP_VPN_IP"
        echo "╠══════════════════════════════════════════════════════════════════╣"
    fi
    
    if $DEPLOY_AZURE && [ -n "$AKS_CLUSTER_NAME" ]; then
        echo "║ AKS Cluster: $AKS_CLUSTER_NAME"
        echo "║ Resource Group: $AZURE_RESOURCE_GROUP"
        echo "║ App Gateway IP: $AKS_APPGW_IP"
        echo "║ Azure VPN Gateway: $AZURE_VPN_IP"
        echo "╠══════════════════════════════════════════════════════════════════╣"
    fi
    
    echo "║                                                                  ║"
    echo "║ NEXT STEPS:                                                      ║"
    echo "║ 1. Update DNS records to point to the Ingress IPs               ║"
    echo "║ 2. Wait for SSL certificates to be provisioned (5-15 mins)      ║"
    echo "║ 3. Access WordPress at your domain to complete setup            ║"
    echo "║ 4. Run load test: ./scripts/load-test.sh                        ║"
    echo "║                                                                  ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
}

# Main execution
main() {
    parse_args "$@"
    
    print_header "WordPress Multi-Cloud Deployment"
    echo "Deployment Options:"
    echo "  - Deploy GCP: $DEPLOY_GCP"
    echo "  - Deploy Azure: $DEPLOY_AZURE"
    echo "  - Deploy K8s: $DEPLOY_K8S"
    echo "  - Deploy Consul: $DEPLOY_CONSUL"
    echo "  - Destroy Mode: $DESTROY_MODE"
    
    if $DESTROY_MODE; then
        destroy_all
        exit 0
    fi
    
    check_prerequisites
    check_authentication
    check_tfvars
    
    # Deploy infrastructure
    if $DEPLOY_GCP; then
        deploy_gcp_infra
    fi
    
    if $DEPLOY_AZURE; then
        deploy_azure_infra
    fi
    
    # Update VPN configurations
    if $DEPLOY_GCP && $DEPLOY_AZURE; then
        update_gcp_vpn
    fi
    
    # Deploy Kubernetes resources
    if $DEPLOY_K8S; then
        if $DEPLOY_GCP; then
            deploy_gke_k8s
        fi
        
        if $DEPLOY_AZURE; then
            deploy_aks_k8s
        fi
    fi
    
    # Deploy Consul
    if $DEPLOY_CONSUL && $DEPLOY_GCP && $DEPLOY_AZURE; then
        deploy_consul
    fi
    
    print_summary
}

# Run main function
main "$@"