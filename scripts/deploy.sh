#!/bin/bash
# deploy.sh - Kolla-Ansible Production Deployment Script
# Author: rasheshpatel <rasheshkumar.patel@gmail.com>
#
# Usage:
#   ./scripts/deploy.sh              # full deployment
#   ./scripts/deploy.sh --dry-run    # show what would run, skip actual deploy

set -euo pipefail

###############################################################################
# Colour codes
###############################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

###############################################################################
# Paths and constants
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
INVENTORY="$REPO_ROOT/inventory/multinode"
KOLLA_CONFIG_DIR="${KOLLA_CONFIG_DIR:-/etc/kolla}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="/var/log"
LOG_FILE="${LOG_DIR}/kolla-deploy-${TIMESTAMP}.log"
DRY_RUN=false

# Parse flags
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
    esac
done

# Create log file (fall back to /tmp if /var/log is not writable)
if ! touch "$LOG_FILE" 2>/dev/null; then
    LOG_DIR="/tmp"
    LOG_FILE="${LOG_DIR}/kolla-deploy-${TIMESTAMP}.log"
    touch "$LOG_FILE"
fi

###############################################################################
# Logging helpers
###############################################################################
log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

log_section() {
    echo -e "\n${BLUE}========== $* ==========${NC}\n" | tee -a "$LOG_FILE"
}

###############################################################################
# Node definitions
###############################################################################
CONTROL_NODES=(10.0.1.11 10.0.1.12 10.0.1.13)
COMPUTE_NODES=(10.0.1.21 10.0.1.22 10.0.1.23 10.0.1.24)
STORAGE_NODES=(10.0.1.31 10.0.1.32 10.0.1.33)
ALL_NODES=("${CONTROL_NODES[@]}" "${COMPUTE_NODES[@]}" "${STORAGE_NODES[@]}")

###############################################################################
# preflight_checks
# - Pings all nodes, reports which are unreachable
# - Checks /var disk space on each node (warn if < 20 GB free)
# - Checks chrony time sync on each node
# Exits non-zero if any critical check fails
###############################################################################
preflight_checks() {
    log_section "Pre-flight Checks"

    local UNREACHABLE=()
    local CRITICAL_FAIL=false

    # ── Connectivity check ───────────────────────────────────────────────────
    log_info "Checking ICMP reachability for all nodes..."
    for node in "${ALL_NODES[@]}"; do
        if ping -c2 -W2 "$node" &>/dev/null; then
            log_info "  [REACHABLE]  $node"
        else
            log_warn "  [UNREACHABLE] $node — cannot ping"
            UNREACHABLE+=("$node")
        fi
    done

    if [[ ${#UNREACHABLE[@]} -gt 0 ]]; then
        log_error "The following nodes are unreachable: ${UNREACHABLE[*]}"
        log_error "Verify network configuration and SSH access before continuing."
        CRITICAL_FAIL=true
    fi

    # ── Disk space check (/var must have >= 20 GB free) ──────────────────────
    log_info "Checking /var disk space on all nodes (need >= 20 GB free)..."
    local SPACE_FAIL=false
    for node in "${ALL_NODES[@]}"; do
        # Skip nodes already identified as unreachable
        if [[ " ${UNREACHABLE[*]} " =~ " ${node} " ]]; then
            continue
        fi

        FREE_KB=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
            "ubuntu@${node}" \
            "df --output=avail /var | tail -1" 2>/dev/null || echo 0)
        FREE_GB=$(( FREE_KB / 1024 / 1024 ))

        if [[ "$FREE_GB" -lt 20 ]]; then
            log_warn "  [LOW DISK]  $node — /var has only ${FREE_GB} GB free (need 20 GB)"
            SPACE_FAIL=true
        else
            log_info "  [DISK OK]   $node — /var has ${FREE_GB} GB free"
        fi
    done

    if $SPACE_FAIL; then
        log_warn "Some nodes have less than 20 GB free on /var."
        log_warn "Docker images and container logs may exhaust disk space."
        log_warn "Proceeding, but consider expanding storage before deployment."
    fi

    # ── Chrony / NTP time sync check ─────────────────────────────────────────
    log_info "Checking NTP time synchronisation on all nodes..."
    local TIME_FAIL=false
    for node in "${ALL_NODES[@]}"; do
        if [[ " ${UNREACHABLE[*]} " =~ " ${node} " ]]; then
            continue
        fi

        CHRONY_OUTPUT=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
            "ubuntu@${node}" \
            "chronyc tracking 2>/dev/null | grep -E 'System time|Last offset'" 2>/dev/null || echo "")

        if [[ -z "$CHRONY_OUTPUT" ]]; then
            log_warn "  [NTP WARN]  $node — could not retrieve chrony status"
            TIME_FAIL=true
        else
            log_info "  [NTP OK]    $node — $CHRONY_OUTPUT"
        fi
    done

    if $TIME_FAIL; then
        log_warn "Time sync could not be verified on all nodes."
        log_warn "Galera and Ceph require clocks within 500ms of each other."
        log_warn "Run: ansible -i inventory/multinode all -m shell -a 'chronyc makestep'"
    fi

    # ── Critical failure gate ─────────────────────────────────────────────────
    if $CRITICAL_FAIL; then
        log_error "Critical preflight checks failed. Aborting deployment."
        exit 1
    fi

    log_info "Pre-flight checks complete."
}

###############################################################################
# check_kolla_installed
# Verifies kolla-ansible is in PATH and prints its version
###############################################################################
check_kolla_installed() {
    log_section "Checking Dependencies"

    if ! command -v kolla-ansible &>/dev/null; then
        log_error "kolla-ansible not found in PATH."
        log_error "Install with: pip install kolla-ansible==2024.1.0 ansible==8.7.0"
        exit 1
    fi

    KOLLA_VERSION=$(kolla-ansible --version 2>&1 | head -1)
    log_info "kolla-ansible: $KOLLA_VERSION"

    if ! command -v ansible &>/dev/null; then
        log_error "ansible not found in PATH."
        exit 1
    fi

    ANSIBLE_VERSION=$(ansible --version 2>&1 | head -1)
    log_info "ansible: $ANSIBLE_VERSION"

    # Verify inventory file exists
    if [[ ! -f "$INVENTORY" ]]; then
        log_error "Inventory not found: $INVENTORY"
        exit 1
    fi
    log_info "Inventory: $INVENTORY"

    # Verify globals.yml exists
    if [[ ! -f "$KOLLA_CONFIG_DIR/globals.yml" ]]; then
        log_error "globals.yml not found at $KOLLA_CONFIG_DIR/globals.yml"
        log_error "Copy from this repo: sudo cp $REPO_ROOT/globals.yml $KOLLA_CONFIG_DIR/globals.yml"
        exit 1
    fi
    log_info "globals.yml: $KOLLA_CONFIG_DIR/globals.yml"

    # Verify passwords.yml exists and is populated
    if [[ ! -f "$KOLLA_CONFIG_DIR/passwords.yml" ]]; then
        log_error "passwords.yml not found at $KOLLA_CONFIG_DIR/passwords.yml"
        log_error "Run: kolla-genpwd"
        exit 1
    fi

    # Check passwords.yml is not all empty (kolla-genpwd has been run)
    EMPTY_PASS=$(grep -c ": $" "$KOLLA_CONFIG_DIR/passwords.yml" 2>/dev/null || echo 0)
    if [[ "$EMPTY_PASS" -gt 10 ]]; then
        log_warn "passwords.yml has ${EMPTY_PASS} empty entries. Run: kolla-genpwd"
    else
        log_info "passwords.yml: populated"
    fi
}

###############################################################################
# run_kolla_stage <stage>
# Generic wrapper that runs a kolla-ansible stage with timing and logging
###############################################################################
run_kolla_stage() {
    local STAGE="$1"
    local START_TIME
    START_TIME=$(date +%s)

    log_section "Running: kolla-ansible ${STAGE}"
    log_info "Stage start: $(date '+%Y-%m-%d %H:%M:%S')"

    if $DRY_RUN; then
        log_warn "[DRY RUN] Would execute: kolla-ansible ${STAGE} -i ${INVENTORY}"
    else
        if ! kolla-ansible "${STAGE}" -i "${INVENTORY}" 2>&1 | tee -a "$LOG_FILE"; then
            log_error "Stage '${STAGE}' FAILED. Check log: $LOG_FILE"
            exit 1
        fi
    fi

    local END_TIME
    END_TIME=$(date +%s)
    local ELAPSED=$(( END_TIME - START_TIME ))
    log_info "Stage '${STAGE}' completed in $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"
}

###############################################################################
# main
###############################################################################
main() {
    log_section "OpenStack Kolla-Ansible Production Deployment"
    log_info "Log file: $LOG_FILE"
    log_info "Inventory: $INVENTORY"
    log_info "Kolla config dir: $KOLLA_CONFIG_DIR"
    $DRY_RUN && log_warn "DRY RUN mode — no actual changes will be made"

    # Step 1: Pre-flight checks
    preflight_checks

    # Step 2: Verify toolchain
    check_kolla_installed

    # Step 3: Confirm deployment
    echo ""
    log_warn "You are about to deploy OpenStack to ALL nodes in the inventory."
    log_warn "This is DESTRUCTIVE on a fresh environment (it will reconfigure Docker, networking, etc.)."
    log_warn "Nodes: ${ALL_NODES[*]}"
    echo ""
    read -rp "Type 'yes' to confirm and proceed with deployment: " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        log_info "Deployment cancelled by user."
        exit 0
    fi
    echo ""

    DEPLOY_START=$(date +%s)

    # Step 4: Bootstrap servers
    run_kolla_stage "bootstrap-servers"

    # Step 5: Prechecks
    run_kolla_stage "prechecks"

    # Step 6: Deploy
    run_kolla_stage "deploy"

    # Step 7: Post-deploy
    run_kolla_stage "post-deploy"

    DEPLOY_END=$(date +%s)
    TOTAL_ELAPSED=$(( DEPLOY_END - DEPLOY_START ))

    # Print success banner
    echo ""
    echo -e "${GREEN}${BLUE}================================================================${NC}"
    echo -e "${GREEN}  OpenStack Deployment Complete!${NC}"
    echo -e "${BLUE}================================================================${NC}"
    printf "  %-28s %s\n" "Total deployment time:" "$(( TOTAL_ELAPSED / 60 ))m $(( TOTAL_ELAPSED % 60 ))s"
    printf "  %-28s %s\n" "VIP address:" "10.0.1.100"
    printf "  %-28s %s\n" "Horizon dashboard:" "http://10.0.1.100/"
    printf "  %-28s %s\n" "Keystone API:" "http://10.0.1.100:5000/v3"
    printf "  %-28s %s\n" "Admin credentials:" "$KOLLA_CONFIG_DIR/admin-openrc.sh"
    printf "  %-28s %s\n" "Full log:" "$LOG_FILE"
    echo -e "${BLUE}================================================================${NC}"
    echo ""
    echo "Next steps:"
    echo "  source $KOLLA_CONFIG_DIR/admin-openrc.sh"
    echo "  openstack service list"
    echo "  bash $SCRIPT_DIR/post-deploy.sh"
    echo "  bash $SCRIPT_DIR/health-check.sh"
    echo ""
}

main "$@"
