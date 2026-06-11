#!/bin/bash
# post-deploy.sh - OpenStack Post-Deployment Resource Setup
# Author: rasheshpatel <rasheshkumar.patel@gmail.com>
#
# Creates initial resources required to validate and use the OpenStack cluster:
#   - Provider (external) and tenant networks
#   - Router with external gateway
#   - Ubuntu 22.04 Glance image
#   - Standard Nova flavors
#   - Default security group rules
#   - Test VM with floating IP and SSH validation

set -euo pipefail

###############################################################################
# Colour codes and logging
###############################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"
}

log_section() {
    echo -e "\n${BLUE}========== $* ==========${NC}\n"
}

###############################################################################
# Source admin credentials
###############################################################################
OPENRC="/etc/kolla/admin-openrc.sh"

if [[ ! -f "$OPENRC" ]]; then
    log_error "Admin openrc not found at $OPENRC"
    log_error "Run 'kolla-ansible post-deploy' first to generate it."
    exit 1
fi

log_info "Sourcing credentials from $OPENRC"
# shellcheck source=/dev/null
source "$OPENRC"

# Verify we can reach Keystone
if ! openstack token issue &>/dev/null; then
    log_error "Cannot authenticate with Keystone at $OS_AUTH_URL"
    log_error "Check that all services are running and VIP 10.0.1.100 is reachable."
    exit 1
fi
log_info "Keystone authentication OK"

###############################################################################
# create_networks
# Creates public (provider/flat) and private (VXLAN tenant) networks
###############################################################################
create_networks() {
    log_section "Creating Networks"

    # -- External / provider network -------------------------------------------
    if openstack network show public-net &>/dev/null 2>&1; then
        log_info "Network 'public-net' already exists — skipping creation"
    else
        log_info "Creating external provider network: public-net"
        openstack network create \
            --share \
            --external \
            --provider-network-type flat \
            --provider-physical-network physnet1 \
            public-net
        log_info "public-net created"
    fi

    if openstack subnet show public-subnet &>/dev/null 2>&1; then
        log_info "Subnet 'public-subnet' already exists — skipping"
    else
        log_info "Creating external subnet: 192.168.100.0/24"
        openstack subnet create \
            --network public-net \
            --subnet-range 192.168.100.0/24 \
            --gateway 192.168.100.1 \
            --allocation-pool start=192.168.100.100,end=192.168.100.200 \
            --dns-nameserver 8.8.8.8 \
            --no-dhcp \
            public-subnet
        log_info "public-subnet created (192.168.100.100 - 192.168.100.200)"
    fi

    # -- Private / tenant network -----------------------------------------------
    if openstack network show private-net &>/dev/null 2>&1; then
        log_info "Network 'private-net' already exists — skipping"
    else
        log_info "Creating tenant VXLAN network: private-net"
        openstack network create \
            --provider-network-type vxlan \
            private-net
        log_info "private-net created"
    fi

    if openstack subnet show private-subnet &>/dev/null 2>&1; then
        log_info "Subnet 'private-subnet' already exists — skipping"
    else
        log_info "Creating private subnet: 10.10.0.0/24"
        openstack subnet create \
            --network private-net \
            --subnet-range 10.10.0.0/24 \
            --gateway 10.10.0.1 \
            --dns-nameserver 8.8.8.8 \
            private-subnet
        log_info "private-subnet created (10.10.0.0/24)"
    fi
}

###############################################################################
# create_router
# Creates a router connecting private-subnet to public-net
###############################################################################
create_router() {
    log_section "Creating Router"

    if openstack router show main-router &>/dev/null 2>&1; then
        log_info "Router 'main-router' already exists — skipping"
        return
    fi

    log_info "Creating router: main-router"
    openstack router create main-router

    log_info "Setting external gateway to public-net"
    openstack router set --external-gateway public-net main-router

    log_info "Adding private-subnet interface to router"
    openstack router add subnet main-router private-subnet

    log_info "main-router created with gateway on public-net"
}

###############################################################################
# upload_images
# Downloads Ubuntu 22.04 Jammy cloud image and uploads to Glance
###############################################################################
upload_images() {
    log_section "Uploading Glance Images"

    IMAGE_NAME="ubuntu-22.04-jammy"
    IMAGE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
    IMAGE_FILE="/tmp/jammy-server-cloudimg-amd64.img"

    if openstack image show "$IMAGE_NAME" &>/dev/null 2>&1; then
        log_info "Image '$IMAGE_NAME' already exists in Glance — skipping"
        return
    fi

    if [[ ! -f "$IMAGE_FILE" ]]; then
        log_info "Downloading Ubuntu 22.04 Jammy cloud image (~600 MB)..."
        log_info "Source: $IMAGE_URL"
        curl -L --progress-bar -o "$IMAGE_FILE" "$IMAGE_URL"
        log_info "Download complete: $IMAGE_FILE"
    else
        log_info "Using cached image: $IMAGE_FILE"
    fi

    log_info "Uploading to Glance as '$IMAGE_NAME'..."
    openstack image create \
        --disk-format qcow2 \
        --container-format bare \
        --public \
        --property min_ram=512 \
        --property min_disk=10 \
        --property os_distro=ubuntu \
        --property os_version="22.04" \
        --file "$IMAGE_FILE" \
        "$IMAGE_NAME"

    log_info "Image '$IMAGE_NAME' uploaded successfully"
    openstack image show "$IMAGE_NAME" -f value -c id -c name -c disk_format -c size
}

###############################################################################
# create_flavors
# Creates standard Nova flavors; skips any that already exist
###############################################################################
create_flavors() {
    log_section "Creating Nova Flavors"

    # Format: "name vcpus ram_mb disk_gb"
    local FLAVORS=(
        "m1.tiny   1  512    10"
        "m1.small  2  2048   20"
        "m1.medium 4  4096   40"
        "m1.large  8  8192   80"
        "m1.xlarge 16 16384  160"
    )

    for flavor_def in "${FLAVORS[@]}"; do
        # Parse fields (allow multiple spaces)
        read -r fname fvcpus fram fdisk <<< "$flavor_def"

        if openstack flavor show "$fname" &>/dev/null 2>&1; then
            log_info "Flavor '$fname' already exists — skipping"
        else
            log_info "Creating flavor: $fname (${fvcpus} vCPU, ${fram} MB RAM, ${fdisk} GB disk)"
            openstack flavor create \
                --vcpus "$fvcpus" \
                --ram "$fram" \
                --disk "$fdisk" \
                --public \
                "$fname"
        fi
    done

    log_info "Flavor summary:"
    openstack flavor list
}

###############################################################################
# create_security_group
# Creates a 'default-sg' security group with SSH, ICMP, and all-egress rules
###############################################################################
create_security_group() {
    log_section "Creating Security Group"

    SG_NAME="default-sg"

    if openstack security group show "$SG_NAME" &>/dev/null 2>&1; then
        log_info "Security group '$SG_NAME' already exists — skipping"
        return
    fi

    log_info "Creating security group: $SG_NAME"
    openstack security group create \
        --description "Default rules: SSH, ICMP, all egress" \
        "$SG_NAME"

    # SSH ingress
    log_info "Adding SSH ingress rule (TCP/22)"
    openstack security group rule create \
        --protocol tcp \
        --dst-port 22 \
        --remote-ip 0.0.0.0/0 \
        --ingress \
        "$SG_NAME"

    # ICMP ingress (ping)
    log_info "Adding ICMP ingress rule"
    openstack security group rule create \
        --protocol icmp \
        --remote-ip 0.0.0.0/0 \
        --ingress \
        "$SG_NAME"

    # All egress (IPv4) — usually already present by default, create if missing
    log_info "Adding all-traffic egress rule (IPv4)"
    openstack security group rule create \
        --protocol any \
        --remote-ip 0.0.0.0/0 \
        --egress \
        "$SG_NAME" 2>/dev/null || log_info "  Egress rule already present"

    log_info "Security group '$SG_NAME' created"
}

###############################################################################
# launch_test_instance
# Launches test-vm-01, assigns a floating IP, and validates SSH connectivity
###############################################################################
launch_test_instance() {
    log_section "Launching Test Instance"

    VM_NAME="test-vm-01"
    FLAVOR="m1.tiny"
    IMAGE="ubuntu-22.04-jammy"
    NETWORK="private-net"
    SG="default-sg"
    FLOATING_IP=""

    if openstack server show "$VM_NAME" &>/dev/null 2>&1; then
        log_info "Instance '$VM_NAME' already exists — skipping creation"
        FLOATING_IP=$(openstack server show "$VM_NAME" \
            -f value -c addresses 2>/dev/null | grep -oP '(?<=floating_ip_address=)\S+' || \
            openstack floating ip list --fixed-ip-address \
                "$(openstack server show "$VM_NAME" -f value -c addresses | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1)" \
                -f value -c "Floating IP Address" 2>/dev/null | head -1 || true)
        log_info "Skipped; existing floating IP: ${FLOATING_IP:-none}"
        return
    fi

    log_info "Creating instance '$VM_NAME' (flavor=$FLAVOR, image=$IMAGE)"
    openstack server create \
        --flavor "$FLAVOR" \
        --image "$IMAGE" \
        --network "$NETWORK" \
        --security-group "$SG" \
        "$VM_NAME"

    # Poll for ACTIVE status (max 5 minutes, every 10 seconds)
    log_info "Waiting for '$VM_NAME' to become ACTIVE (timeout: 5 min)..."
    WAIT_MAX=300
    WAIT_INTERVAL=10
    WAITED=0
    STATUS="BUILD"

    while [[ "$STATUS" != "ACTIVE" && $WAITED -lt $WAIT_MAX ]]; do
        sleep "$WAIT_INTERVAL"
        WAITED=$(( WAITED + WAIT_INTERVAL ))
        STATUS=$(openstack server show "$VM_NAME" -f value -c status 2>/dev/null || echo "UNKNOWN")
        log_info "  Status: $STATUS (${WAITED}s elapsed)"

        if [[ "$STATUS" == "ERROR" ]]; then
            log_error "Instance '$VM_NAME' entered ERROR state."
            openstack server show "$VM_NAME"
            openstack console log show "$VM_NAME" 2>/dev/null | tail -30 || true
            return 1
        fi
    done

    if [[ "$STATUS" != "ACTIVE" ]]; then
        log_error "Instance '$VM_NAME' did not reach ACTIVE within ${WAIT_MAX}s (current: $STATUS)"
        return 1
    fi
    log_info "Instance '$VM_NAME' is ACTIVE"

    # Assign floating IP
    log_info "Allocating floating IP from public-net..."
    FLOATING_IP=$(openstack floating ip create public-net -f value -c floating_ip_address)
    log_info "Floating IP allocated: $FLOATING_IP"

    log_info "Associating floating IP $FLOATING_IP with $VM_NAME"
    openstack server add floating ip "$VM_NAME" "$FLOATING_IP"

    # Wait 60s for the instance to boot and SSH daemon to start
    log_info "Waiting 60s for instance boot and SSH startup..."
    sleep 60

    # Poll SSH availability (nc -z test, no authentication)
    log_info "Testing SSH reachability on $FLOATING_IP:22..."
    SSH_AVAILABLE=false
    for i in {1..12}; do
        if nc -z -w5 "$FLOATING_IP" 22 2>/dev/null; then
            SSH_AVAILABLE=true
            break
        fi
        log_info "  SSH not yet available — retry $i/12 (waiting 10s)"
        sleep 10
    done

    if $SSH_AVAILABLE; then
        log_info "  [PASS] SSH port 22 is reachable on $FLOATING_IP"
    else
        log_warn "  [FAIL] SSH not reachable on $FLOATING_IP after 120s"
        log_warn "  Check security groups and router configuration."
    fi

    log_info "Test instance summary:"
    printf "  %-20s %s\n" "Instance name:" "$VM_NAME"
    printf "  %-20s %s\n" "Floating IP:" "$FLOATING_IP"
    printf "  %-20s %s\n" "SSH test:" "$( $SSH_AVAILABLE && echo PASS || echo FAIL )"
}

###############################################################################
# print_summary
# Prints a summary table of deployed endpoints and resources
###############################################################################
print_summary() {
    log_section "Deployment Summary"

    echo "OpenStack API Endpoints:"
    echo "------------------------"
    openstack endpoint list --interface public \
        -c "Service Name" -c "Service Type" -c "URL" 2>/dev/null || true

    echo ""
    echo "================================================================"
    printf "  %-30s %s\n" "Horizon Dashboard:" "http://10.0.1.100/"
    printf "  %-30s %s\n" "Keystone API:" "http://10.0.1.100:5000/v3"
    printf "  %-30s %s\n" "Admin credentials:" "source /etc/kolla/admin-openrc.sh"
    printf "  %-30s %s\n" "Grafana monitoring:" "http://10.0.1.100:3000/"
    echo "================================================================"
    echo ""
    echo "To begin using OpenStack:"
    echo "  source /etc/kolla/admin-openrc.sh"
    echo "  openstack server list"
    echo "  openstack network list"
    echo ""
}

###############################################################################
# main
###############################################################################
main() {
    log_section "OpenStack Post-Deployment Initialisation"

    create_networks
    create_router
    upload_images
    create_flavors
    create_security_group
    launch_test_instance
    print_summary

    log_info "Post-deployment complete."
}

main "$@"
