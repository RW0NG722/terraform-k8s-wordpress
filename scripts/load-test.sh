#!/bin/bash
# =============================================================================
# LOAD TEST SCRIPT FOR AUTOSCALER DEMONSTRATION
# =============================================================================
# This script generates load on WordPress to demonstrate cluster autoscaling.
#
# PREREQUISITES:
#   - hey (HTTP load generator): go install github.com/rakyll/hey@latest
#   - OR Apache Bench (ab): apt-get install apache2-utils
#   - OR curl (fallback)
#
# USAGE:
#   chmod +x load-test.sh
#   ./load-test.sh [gke|aks] [--duration 60] [--concurrent 50]
#
# WHAT TO EXPECT:
#   1. Load increases CPU/memory usage
#   2. HPA scales WordPress pods (within seconds)
#   3. Cluster Autoscaler adds nodes (2-5 minutes)
#   4. After load stops, pods scale down (5 minutes)
#   5. Nodes scale down (10-15 minutes after load stops)
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Defaults
CLUSTER="gke"
DURATION=120
CONCURRENT=100
RATE=500  # Requests per second

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        gke|aks)
            CLUSTER="$1"
            shift
            ;;
        --duration)
            DURATION="$2"
            shift 2
            ;;
        --concurrent)
            CONCURRENT="$2"
            shift 2
            ;;
        --rate)
            RATE="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [gke|aks] [--duration SECONDS] [--concurrent NUM] [--rate RPS]"
            echo ""
            echo "Arguments:"
            echo "  gke|aks        Target cluster (default: gke)"
            echo "  --duration     Test duration in seconds (default: 120)"
            echo "  --concurrent   Concurrent connections (default: 100)"
            echo "  --rate         Requests per second (default: 500)"
            exit 0
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

print_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

# Configure kubectl for the target cluster
configure_kubectl() {
    print_status "Configuring kubectl for $CLUSTER..."
    
    if [ "$CLUSTER" == "gke" ]; then
        cd "$PROJECT_ROOT/gcp"
        local cluster=$(terraform output -raw cluster_name 2>/dev/null)
        local region=$(terraform output -raw cluster_location 2>/dev/null)
        local project=$(grep 'project_id' terraform.tfvars | cut -d'"' -f2)
        gcloud container clusters get-credentials "$cluster" --region "$region" --project "$project"
        cd "$PROJECT_ROOT"
    else
        cd "$PROJECT_ROOT/azure"
        local cluster=$(terraform output -raw cluster_name 2>/dev/null)
        local rg=$(terraform output -raw resource_group_name 2>/dev/null)
        az aks get-credentials --resource-group "$rg" --name "$cluster" --overwrite-existing
        cd "$PROJECT_ROOT"
    fi
}

# Get WordPress URL
get_wordpress_url() {
    print_status "Getting WordPress URL..."
    
    local url=""
    
    # Try to get from Ingress
    local host=$(kubectl get ingress wordpress-ingress -n wordpress -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "")
    
    if [ -n "$host" ] && [ "$host" != "" ]; then
        url="https://$host"
    else
        # Fallback to LoadBalancer IP
        local ip=$(kubectl get ingress wordpress-ingress -n wordpress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        if [ -n "$ip" ]; then
            url="http://$ip"
        fi
    fi
    
    if [ -z "$url" ]; then
        # Try service directly
        local svc_ip=$(kubectl get svc wordpress -n wordpress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        if [ -n "$svc_ip" ]; then
            url="http://$svc_ip"
        fi
    fi
    
    if [ -z "$url" ]; then
        print_error "Could not determine WordPress URL"
        print_info "You can port-forward manually: kubectl port-forward svc/wordpress 8080:80 -n wordpress"
        exit 1
    fi
    
    echo "$url"
}

# Show current cluster state
show_cluster_state() {
    echo ""
    echo -e "${BLUE}=== Current Cluster State ===${NC}"
    echo ""
    
    echo "Nodes:"
    kubectl get nodes -o wide
    echo ""
    
    echo "Pods in wordpress namespace:"
    kubectl get pods -n wordpress -o wide
    echo ""
    
    echo "HPA status:"
    kubectl get hpa -n wordpress
    echo ""
    
    echo "Resource usage:"
    kubectl top nodes 2>/dev/null || echo "Metrics not available yet"
    echo ""
    kubectl top pods -n wordpress 2>/dev/null || echo "Metrics not available yet"
}

# Monitor cluster during load test
monitor_cluster() {
    local interval=10
    local elapsed=0
    
    while [ $elapsed -lt $DURATION ]; do
        clear
        echo -e "${BLUE}=== Load Test Monitoring (${elapsed}s / ${DURATION}s) ===${NC}"
        echo ""
        
        echo "Nodes:"
        kubectl get nodes --no-headers | awk '{print $1, $2, $5}'
        echo ""
        
        echo "WordPress Pods:"
        kubectl get pods -n wordpress -l app.kubernetes.io/name=wordpress --no-headers 2>/dev/null | awk '{print $1, $3, $4}'
        echo ""
        
        echo "HPA:"
        kubectl get hpa wordpress-hpa -n wordpress --no-headers 2>/dev/null | awk '{print "Replicas:", $6, "| Current CPU:", $3}'
        echo ""
        
        echo "Resource Usage:"
        kubectl top pods -n wordpress --no-headers 2>/dev/null | head -5 || echo "Waiting for metrics..."
        echo ""
        
        echo -e "${YELLOW}Press Ctrl+C to stop monitoring${NC}"
        
        sleep $interval
        elapsed=$((elapsed + interval))
    done
}

# Run load test with hey
run_hey_test() {
    local url="$1"
    
    print_status "Running load test with hey..."
    print_info "URL: $url"
    print_info "Duration: ${DURATION}s"
    print_info "Concurrent: $CONCURRENT"
    print_info "Rate: $RATE requests/second"
    
    hey -z "${DURATION}s" -c "$CONCURRENT" -q "$RATE" "$url/"
}

# Run load test with Apache Bench
run_ab_test() {
    local url="$1"
    
    print_status "Running load test with Apache Bench..."
    print_info "URL: $url"
    
    local requests=$((RATE * DURATION))
    ab -n "$requests" -c "$CONCURRENT" -t "$DURATION" "$url/"
}

# Run load test with curl (fallback)
run_curl_test() {
    local url="$1"
    
    print_status "Running load test with curl..."
    print_info "URL: $url"
    print_info "This is a simple test. Consider installing 'hey' for better results."
    
    local end_time=$((SECONDS + DURATION))
    local count=0
    
    while [ $SECONDS -lt $end_time ]; do
        for i in $(seq 1 $CONCURRENT); do
            curl -s -o /dev/null -w "" "$url/" &
        done
        wait
        count=$((count + CONCURRENT))
        echo "Sent $count requests..."
        sleep 1
    done
    
    echo "Total requests sent: $count"
}

# Generate CPU-intensive requests
run_cpu_load() {
    local url="$1"
    
    print_status "Generating CPU-intensive load..."
    
    # Create a CPU-intensive PHP script via WordPress
    # This simulates heavy computation
    
    local end_time=$((SECONDS + DURATION))
    
    while [ $SECONDS -lt $end_time ]; do
        for i in $(seq 1 $CONCURRENT); do
            # Multiple concurrent requests to WordPress
            curl -s -o /dev/null "$url/?s=$(openssl rand -hex 16)" &
            curl -s -o /dev/null "$url/wp-login.php" &
        done
        sleep 0.5
    done
}

# Main load test function
run_load_test() {
    local url="$1"
    
    echo ""
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}  Load Test Configuration${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""
    echo "  Target:      $CLUSTER"
    echo "  URL:         $url"
    echo "  Duration:    ${DURATION} seconds"
    echo "  Concurrent:  $CONCURRENT connections"
    echo "  Rate:        $RATE requests/second"
    echo ""
    
    read -p "Start load test? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        print_status "Cancelled"
        exit 0
    fi
    
    # Start monitoring in background
    monitor_cluster &
    MONITOR_PID=$!
    
    # Run the load test
    if command -v hey &> /dev/null; then
        run_hey_test "$url" 2>&1 | tee /tmp/load-test-results.txt
    elif command -v ab &> /dev/null; then
        run_ab_test "$url" 2>&1 | tee /tmp/load-test-results.txt
    else
        run_curl_test "$url"
    fi
    
    # Stop monitoring
    kill $MONITOR_PID 2>/dev/null || true
    
    print_success "Load test completed!"
}

# Show post-test analysis
show_analysis() {
    echo ""
    echo -e "${BLUE}=== Post-Test Analysis ===${NC}"
    echo ""
    
    echo "Final Cluster State:"
    show_cluster_state
    
    echo ""
    echo "Events during test:"
    kubectl get events -n wordpress --sort-by='.lastTimestamp' | tail -20
    
    echo ""
    echo "Node scaling events:"
    kubectl get events -A --field-selector reason=ScaledUpGroup 2>/dev/null | tail -10 || echo "No scale-up events found"
    kubectl get events -A --field-selector reason=ScaleDown 2>/dev/null | tail -10 || echo "No scale-down events found"
    
    if [ -f /tmp/load-test-results.txt ]; then
        echo ""
        echo "Load test results saved to: /tmp/load-test-results.txt"
    fi
}

# Cleanup function
cleanup() {
    echo ""
    print_status "Cleaning up..."
    kill $MONITOR_PID 2>/dev/null || true
}

trap cleanup EXIT

# Main
main() {
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}  Autoscaler Load Test${NC}"
    echo -e "${BLUE}============================================${NC}"
    
    configure_kubectl
    
    echo ""
    echo "Initial cluster state:"
    show_cluster_state
    
    local url=$(get_wordpress_url)
    print_success "WordPress URL: $url"
    
    # Verify WordPress is accessible
    print_status "Verifying WordPress is accessible..."
    if curl -s -o /dev/null -w "%{http_code}" "$url/" | grep -q "200\|301\|302"; then
        print_success "WordPress is accessible"
    else
        print_error "WordPress is not accessible. Please check the deployment."
        exit 1
    fi
    
    run_load_test "$url"
    show_analysis
    
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  Load Test Complete${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo "To observe autoscaling:"
    echo "  1. Watch pods:  kubectl get pods -n wordpress -w"
    echo "  2. Watch nodes: kubectl get nodes -w"
    echo "  3. Watch HPA:   kubectl get hpa -n wordpress -w"
    echo ""
    echo "The cluster autoscaler may take 2-5 minutes to add nodes."
    echo "Scale-down typically occurs 10-15 minutes after load decreases."
}

main