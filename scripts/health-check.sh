#!/bin/bash
# health-check.sh - OpenStack Cluster Health Check
# Author: rasheshpatel <rasheshkumar.patel@gmail.com>
#
# Checks:
#   - OpenStack service and endpoint status
#   - Nova compute service state
#   - Neutron agent state
#   - Cinder volume service state
#   - Ceph cluster health, OSD count, and pool usage
#   - Nova hypervisor capacity
#   - MariaDB Galera cluster state
#   - RabbitMQ cluster state
#   - HAProxy backend health

set -uo pipefail

###############################################################################
# Colour codes and helpers
###############################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS_COUNT=0
FAILED_CHECKS=0

pass() {
    echo -e "  ${GREEN}[PASS]${NC} $*"
    PASS_COUNT=$(( PASS_COUNT + 1 ))
}

fail() {
    echo -e "  ${RED}[FAIL]${NC} $*"
    FAILED_CHECKS=$(( FAILED_CHECKS + 1 ))
}

warn() {
    echo -e "  ${YELLOW}[WARN]${NC} $*"
}

info() {
    echo -e "         $*"
}

log_section() {
    echo -e "\n${BLUE}========== $* ==========${NC}"
}

###############################################################################
# Configuration
###############################################################################
OPENRC="/etc/kolla/admin-openrc.sh"
CEPH_MON="10.0.1.31"
CONTROLLER_PRIMARY="10.0.1.11"
EXPECTED_SERVICES=(keystone nova neutron glance cinderv3 heat barbican)
EXPECTED_GALERA_SIZE=3
EXPECTED_RABBIT_NODES=3

###############################################################################
# Source credentials
###############################################################################
if [[ ! -f "$OPENRC" ]]; then
    echo -e "${RED}[ERROR]${NC} Admin openrc not found: $OPENRC"
    echo "Run: kolla-ansible post-deploy -i inventory/multinode"
    exit 1
fi
# shellcheck source=/dev/null
source "$OPENRC"

###############################################################################
# check_openstack_services
# Verifies all expected OpenStack services exist and their endpoints are enabled
###############################################################################
check_openstack_services() {
    log_section "OpenStack Services and Endpoints"

    # Check each expected service is present
    for svc in "${EXPECTED_SERVICES[@]}"; do
        ENABLED=$(openstack service list -f value -c Name -c Enabled 2>/dev/null | \
            grep -i "^${svc} " | awk '{print $2}' | head -1 || echo "")

        if [[ "$ENABLED" == "True" ]]; then
            pass "Service enabled: $svc"
        elif [[ -z "$ENABLED" ]]; then
            fail "Service not found: $svc"
        else
            fail "Service disabled: $svc (enabled=$ENABLED)"
        fi
    done

    # Check endpoints exist for each expected service
    echo ""
    info "Endpoint check (public interface):"
    for svc in "${EXPECTED_SERVICES[@]}"; do
        URL=$(openstack endpoint list --service "$svc" --interface public \
            -f value -c URL 2>/dev/null | head -1 || echo "")
        if [[ -n "$URL" ]]; then
            pass "Endpoint present: $svc -> $URL"
        else
            fail "Endpoint missing for service: $svc"
        fi
    done
}

###############################################################################
# check_compute_services
# Reports any nova-* services in down or disabled state
###############################################################################
check_compute_services() {
    log_section "Nova Compute Services"

    # Capture full list once
    COMPUTE_SERVICES=$(openstack compute service list \
        -f value -c Host -c Binary -c State -c Status 2>/dev/null || echo "")

    if [[ -z "$COMPUTE_SERVICES" ]]; then
        fail "Could not retrieve compute service list"
        return
    fi

    while IFS= read -r line; do
        read -r host binary state status <<< "$line"
        if [[ "$state" == "up" && "$status" == "enabled" ]]; then
            pass "$binary on $host: up/enabled"
        elif [[ "$state" == "up" && "$status" == "disabled" ]]; then
            warn "$binary on $host: up but DISABLED (maintenance?)"
        else
            fail "$binary on $host: state=$state status=$status"
        fi
    done <<< "$COMPUTE_SERVICES"
}

###############################################################################
# check_network_agents
# Reports any Neutron agents that are down or admin-disabled
###############################################################################
check_network_agents() {
    log_section "Neutron Network Agents"

    AGENTS=$(openstack network agent list \
        -f value -c Host -c Binary -c Alive -c AdminStateUp 2>/dev/null || echo "")

    if [[ -z "$AGENTS" ]]; then
        fail "Could not retrieve network agent list"
        return
    fi

    while IFS= read -r line; do
        read -r host binary alive admin_up <<< "$line"
        if [[ "$alive" == "True" && "$admin_up" == "True" ]]; then
            pass "$binary on $host: alive/enabled"
        elif [[ "$alive" == "False" ]]; then
            fail "$binary on $host: NOT ALIVE (admin_state_up=$admin_up)"
        elif [[ "$admin_up" == "False" ]]; then
            warn "$binary on $host: alive but admin-disabled"
        else
            fail "$binary on $host: alive=$alive admin_state_up=$admin_up"
        fi
    done <<< "$AGENTS"
}

###############################################################################
# check_volume_services
# Reports any Cinder services in down state
###############################################################################
check_volume_services() {
    log_section "Cinder Volume Services"

    VOL_SERVICES=$(openstack volume service list \
        -f value -c Host -c Binary -c State -c Status 2>/dev/null || echo "")

    if [[ -z "$VOL_SERVICES" ]]; then
        fail "Could not retrieve volume service list"
        return
    fi

    while IFS= read -r line; do
        read -r host binary state status <<< "$line"
        if [[ "$state" == "up" && "$status" == "enabled" ]]; then
            pass "$binary on $host: up/enabled"
        elif [[ "$state" == "up" && "$status" == "disabled" ]]; then
            warn "$binary on $host: up but DISABLED"
        else
            fail "$binary on $host: state=$state status=$status"
        fi
    done <<< "$VOL_SERVICES"
}

###############################################################################
# check_ceph_health
# SSHs to the primary Ceph monitor and checks health, df, and OSD stats
###############################################################################
check_ceph_health() {
    log_section "Ceph Storage Health"

    # Health check
    CEPH_HEALTH=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "ubuntu@${CEPH_MON}" "sudo ceph health 2>/dev/null" || echo "UNREACHABLE")

    if [[ "$CEPH_HEALTH" == "HEALTH_OK" ]]; then
        pass "Ceph health: HEALTH_OK"
    elif [[ "$CEPH_HEALTH" == "UNREACHABLE" ]]; then
        fail "Cannot reach Ceph monitor at $CEPH_MON"
        return
    elif echo "$CEPH_HEALTH" | grep -q "HEALTH_WARN"; then
        warn "Ceph health: $CEPH_HEALTH (investigate but non-critical)"
    else
        fail "Ceph health: $CEPH_HEALTH"
    fi

    # Pool usage
    info "Pool usage (ceph df):"
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "ubuntu@${CEPH_MON}" "sudo ceph df 2>/dev/null" 2>/dev/null | \
        while IFS= read -r line; do info "  $line"; done || true

    # OSD stats
    OSD_STAT=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "ubuntu@${CEPH_MON}" "sudo ceph osd stat 2>/dev/null" || echo "unavailable")
    info "OSD stats: $OSD_STAT"

    # Check for expected OSD count (3 nodes)
    OSD_IN=$(echo "$OSD_STAT" | grep -oP '\d+(?= osds:)' || echo "0")
    if [[ "$OSD_IN" -ge 3 ]]; then
        pass "Ceph OSD count: $OSD_IN OSDs in cluster"
    else
        fail "Ceph OSD count: only $OSD_IN OSDs found (expected >= 3)"
    fi
}

###############################################################################
# check_hypervisors
# Shows Nova hypervisor capacity (total vCPU, RAM, disk)
###############################################################################
check_hypervisors() {
    log_section "Nova Hypervisors"

    HYPERVISOR_LIST=$(openstack hypervisor list \
        -f value -c "Hypervisor Hostname" -c "vCPUs" -c "Memory MB" -c "Local GB" \
        2>/dev/null || echo "")

    if [[ -z "$HYPERVISOR_LIST" ]]; then
        fail "Could not retrieve hypervisor list"
        return
    fi

    info "Hypervisor roster:"
    printf "    %-35s %8s %10s %10s\n" "Hostname" "vCPUs" "Memory_MB" "Local_GB"
    printf "    %-35s %8s %10s %10s\n" "--------" "-----" "---------" "--------"

    while IFS= read -r line; do
        read -r hostname vcpus mem_mb local_gb <<< "$line"
        printf "    %-35s %8s %10s %10s\n" "$hostname" "$vcpus" "$mem_mb" "$local_gb"
        pass "Hypervisor: $hostname ($vcpus vCPUs, $mem_mb MB RAM)"
    done <<< "$HYPERVISOR_LIST"

    # Aggregate stats
    info ""
    info "Aggregate capacity:"
    openstack hypervisor stats show 2>/dev/null | \
        while IFS= read -r line; do info "  $line"; done || true
}

###############################################################################
# check_mariadb
# SSHs to the primary controller and checks Galera cluster state
###############################################################################
check_mariadb() {
    log_section "MariaDB Galera Cluster"

    # Read DB root password from passwords.yml (kolla convention)
    DB_PASS=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "ubuntu@${CONTROLLER_PRIMARY}" \
        "sudo grep '^database_password:' /etc/kolla/passwords.yml | awk '{print \$2}'" \
        2>/dev/null || echo "${DB_ROOT_PASSWORD:-changeme}")

    WSREP_OUT=$(ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=no \
        "ubuntu@${CONTROLLER_PRIMARY}" \
        "sudo docker exec mariadb mysql -u root -p'${DB_PASS}' -Nse \
         \"SHOW STATUS LIKE 'wsrep_%';\" 2>/dev/null | grep -E 'wsrep_cluster_size|wsrep_local_state_comment|wsrep_ready|wsrep_connected'" \
        2>/dev/null || echo "UNREACHABLE")

    if [[ "$WSREP_OUT" == "UNREACHABLE" ]]; then
        fail "Cannot SSH to $CONTROLLER_PRIMARY or cannot exec into mariadb container"
        return
    fi

    # Parse cluster size
    CLUSTER_SIZE=$(echo "$WSREP_OUT" | grep "wsrep_cluster_size" | awk '{print $2}' || echo "0")
    LOCAL_STATE=$(echo "$WSREP_OUT" | grep "wsrep_local_state_comment" | awk '{print $2}' || echo "Unknown")
    WSREP_READY=$(echo "$WSREP_OUT" | grep "wsrep_ready" | awk '{print $2}' || echo "OFF")
    WSREP_CONN=$(echo "$WSREP_OUT" | grep "wsrep_connected" | awk '{print $2}' || echo "OFF")

    if [[ "$CLUSTER_SIZE" == "$EXPECTED_GALERA_SIZE" ]]; then
        pass "Galera cluster size: $CLUSTER_SIZE (expected $EXPECTED_GALERA_SIZE)"
    else
        fail "Galera cluster size: $CLUSTER_SIZE (expected $EXPECTED_GALERA_SIZE)"
    fi

    if [[ "$LOCAL_STATE" == "Synced" ]]; then
        pass "Galera local state: Synced"
    else
        fail "Galera local state: $LOCAL_STATE (expected Synced)"
    fi

    if [[ "$WSREP_READY" == "ON" ]]; then
        pass "Galera wsrep_ready: ON"
    else
        fail "Galera wsrep_ready: $WSREP_READY"
    fi

    info "wsrep_connected: $WSREP_CONN"
}

###############################################################################
# check_rabbitmq
# SSHs to the primary controller and verifies a 3-node RabbitMQ cluster
###############################################################################
check_rabbitmq() {
    log_section "RabbitMQ Message Queue"

    RABBIT_OUT=$(ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=no \
        "ubuntu@${CONTROLLER_PRIMARY}" \
        "sudo docker exec rabbitmq rabbitmqctl cluster_status 2>/dev/null" \
        2>/dev/null || echo "UNREACHABLE")

    if [[ "$RABBIT_OUT" == "UNREACHABLE" ]]; then
        fail "Cannot SSH to $CONTROLLER_PRIMARY or rabbitmq container is not running"
        return
    fi

    # Count running nodes
    RUNNING_NODES=$(echo "$RABBIT_OUT" | grep -c "rabbit@" || echo 0)

    if [[ "$RUNNING_NODES" -ge "$EXPECTED_RABBIT_NODES" ]]; then
        pass "RabbitMQ running nodes: $RUNNING_NODES (expected $EXPECTED_RABBIT_NODES)"
    else
        fail "RabbitMQ running nodes: $RUNNING_NODES (expected $EXPECTED_RABBIT_NODES)"
    fi

    # Check for partitions
    if echo "$RABBIT_OUT" | grep -q "partitions"; then
        PARTITIONS=$(echo "$RABBIT_OUT" | grep -A2 "partitions" | head -5)
        if echo "$PARTITIONS" | grep -q "\[\]"; then
            pass "RabbitMQ partitions: none (healthy)"
        else
            fail "RabbitMQ PARTITION DETECTED: $PARTITIONS"
            info "Fix: ssh to a secondary node and rejoin: rabbitmqctl reset && rabbitmqctl join_cluster rabbit@controller01"
        fi
    else
        pass "RabbitMQ partitions: not detected"
    fi

    info "Cluster status excerpt:"
    echo "$RABBIT_OUT" | grep -E "running_nodes|cluster_name|disk_free_limit" | \
        while IFS= read -r line; do info "  $line"; done || true
}

###############################################################################
# check_haproxy
# Curls the HAProxy stats page and checks for DOWN backends
###############################################################################
check_haproxy() {
    log_section "HAProxy Load Balancer"

    # HAProxy stats are exposed at port 1984 by default in Kolla
    STATS_URL="http://10.0.1.100:1984/stats;csv"

    if ! command -v curl &>/dev/null; then
        warn "curl not available — skipping HAProxy check"
        return
    fi

    STATS=$(curl -s --max-time 10 "$STATS_URL" 2>/dev/null || echo "")

    if [[ -z "$STATS" ]]; then
        fail "Cannot reach HAProxy stats at $STATS_URL"
        info "Verify: haproxy container is running and stats are enabled"
        return
    fi

    pass "HAProxy stats page is accessible"

    # Parse CSV stats: field 2 = backend, field 18 = status
    DOWN_BACKENDS=$(echo "$STATS" | awk -F',' 'NR>2 && $18 ~ /DOWN/ {print $1, $2, $18}')

    if [[ -z "$DOWN_BACKENDS" ]]; then
        pass "HAProxy backends: all UP"
    else
        while IFS= read -r line; do
            fail "HAProxy DOWN backend: $line"
        done <<< "$DOWN_BACKENDS"
    fi

    # Count total backends
    TOTAL=$(echo "$STATS" | awk -F',' 'NR>2 && $2 != "FRONTEND" && $2 != "BACKEND"' | wc -l)
    info "Total HAProxy server entries: $TOTAL"
}

###############################################################################
# print_summary
# Prints overall PASS/FAIL count and exits with 1 if any check failed
###############################################################################
print_summary() {
    log_section "Health Check Summary"

    TOTAL=$(( PASS_COUNT + FAILED_CHECKS ))
    echo ""
    printf "  %-20s %d\n" "Total checks run:" "$TOTAL"
    printf "  %-20s %d\n" "Passed:" "$PASS_COUNT"
    printf "  %-20s %d\n" "Failed:" "$FAILED_CHECKS"
    echo ""

    if [[ "$FAILED_CHECKS" -eq 0 ]]; then
        echo -e "${GREEN}  Cluster health: ALL CHECKS PASSED${NC}"
    else
        echo -e "${RED}  Cluster health: $FAILED_CHECKS CHECK(S) FAILED${NC}"
        echo ""
        echo "  Review the output above for details on failed checks."
        echo "  Refer to README.md 'Common Issues' section for remediation steps."
    fi
    echo ""
}

###############################################################################
# main
###############################################################################
main() {
    log_section "OpenStack Cluster Health Check"
    echo "  Date:       $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Auth URL:   $OS_AUTH_URL"
    echo "  Region:     ${OS_REGION_NAME:-RegionOne}"
    echo "  Project:    ${OS_PROJECT_NAME:-admin}"

    check_openstack_services
    check_compute_services
    check_network_agents
    check_volume_services
    check_ceph_health
    check_hypervisors
    check_mariadb
    check_rabbitmq
    check_haproxy
    print_summary

    if [[ "$FAILED_CHECKS" -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
