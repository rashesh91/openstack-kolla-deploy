# Operational Runbook — Lintel Labs @ CtrlS Data Center

Day-0 deployment, Day-1 verification, and Day-2 operations for the OpenStack cluster.

---

## Pre-Deployment Checklist

Run this before every fresh deploy or major reconfigure.

### Infrastructure
- [ ] All 10 nodes are reachable from deploy01: `ansible -i inventory/multinode all -m ping`
- [ ] All nodes have ≥ 200 GB free on `/var/lib/docker`
- [ ] Time is in sync across all nodes (< 1s offset): `ansible all -m command -a "chronyc tracking"`
- [ ] eno2 interface is UP and has no IP (will be used by OVS): `ip link show eno2`
- [ ] Root SSH access from deploy01 to all nodes (or `ubuntu` user with sudo)

### Ceph (External)
- [ ] Ceph cluster is healthy: `ceph status` shows `HEALTH_OK`
- [ ] Ceph pools exist: `images`, `volumes`, `vms`, `backups`
- [ ] Keyring files placed at `/etc/kolla/config/{nova,cinder,glance}/`
- [ ] `ceph.conf` files placed alongside each keyring

### Kolla Config
- [ ] `globals.yml` copied to `/etc/kolla/globals.yml`
- [ ] `config/` directory copied to `/etc/kolla/config/`
- [ ] VIPs are correct: `kolla_internal_vip_address`, `kolla_external_vip_address`
- [ ] `rbd_secret_uuid` in `config/nova/nova.conf` is set to a real UUID (not the placeholder)
- [ ] `rabbitmq_cluster_cookie` is changed from the default placeholder
- [ ] `kolla-genpwd` has been run: `/etc/kolla/passwords.yml` exists and is populated

---

## Deployment Procedure

`scripts/deploy.sh` automates all steps. To run manually step by step:

```bash
# Step 1 — Install Python dependencies on all bare-metal nodes (~5 min)
kolla-ansible -i inventory/multinode bootstrap-servers

# Step 2 — Verify configuration and requirements (~3 min)
kolla-ansible -i inventory/multinode prechecks
# Fix any reported issues before proceeding

# Step 3 — Pull container images on all nodes (~20-40 min depending on bandwidth)
kolla-ansible -i inventory/multinode pull

# Step 4 — Deploy OpenStack (~30-60 min first time)
kolla-ansible -i inventory/multinode deploy

# Step 5 — Generate admin credentials
kolla-ansible -i inventory/multinode post-deploy
source /etc/kolla/admin-openrc.sh

# Step 6 — Create initial resources (networks, flavors, test VM)
./scripts/post-deploy.sh

# Step 7 — Verify everything
./scripts/health-check.sh
```

**Total first-time deployment time: ~2 hours**

---

## Post-Deploy Resources

`scripts/post-deploy.sh` creates the following on a fresh cluster:

| Resource | Details |
|----------|---------|
| External network | `public-net` — flat, physnet1, 192.168.100.0/24, gateway .1, floating pool .100–.200 |
| Tenant network | `private-net` — VXLAN, 10.10.0.0/24 |
| Router | `main-router` — connects private-net to public-net |
| VM image | Ubuntu 22.04 Jammy (downloaded from cloud-images.ubuntu.com) |
| Flavors | m1.tiny (1c/512MB), m1.small (1c/2GB), m1.medium (2c/4GB), m1.large (4c/8GB), m1.xlarge (8c/16GB) |
| Security group | `default` — SSH (22), ICMP, all egress |
| Test VM | `test-vm-01` — m1.small, private-net, floating IP, SSH validated |

---

## Day-2 Operations

### Reconfigure a Single Service After Config Change

```bash
# Edit the config overlay on deploy node:
vim /etc/kolla/config/nova/nova.conf

# Push config to running containers only (no restart):
kolla-ansible -i inventory/multinode reconfigure --tags nova

# Full restart with new config:
kolla-ansible -i inventory/multinode deploy --tags nova
```

### Add a New Compute Node

```bash
# 1. Add the new node to inventory/multinode under [compute]
vim inventory/multinode
# Add: 10.0.1.25 ansible_user=ubuntu ansible_become=true

# 2. Bootstrap the new node
kolla-ansible -i inventory/multinode bootstrap-servers --limit 10.0.1.25

# 3. Deploy nova-compute and OVS agent only
kolla-ansible -i inventory/multinode deploy --limit 10.0.1.25

# 4. Verify it appears in Nova
openstack compute service list --service nova-compute
```

### Upgrade OpenStack Release

```bash
# Update kolla-ansible version first:
pip install -U kolla-ansible

# Pull new container images
kolla-ansible -i inventory/multinode pull

# Run upgrade (performs rolling restart per service)
kolla-ansible -i inventory/multinode upgrade

# Verify
openstack --version && openstack service list
```

### Restart a Single Service on All Controllers

```bash
# Example: restart Neutron server after config change
ansible -i inventory/multinode control -m command \
  -a "docker restart neutron_server"

# Or via kolla-ansible:
kolla-ansible -i inventory/multinode reconfigure --tags neutron
```

### Live-Migrate a VM

```bash
# List VMs and their hosts
openstack server list --long -c ID -c Name -c Host

# Migrate to any available host
openstack server migrate --live-migration --os-compute-api-version 2.30 SERVER_ID

# Migrate to a specific host
openstack server migrate --live-migration --host compute03 SERVER_ID

# Wait for migration completion
openstack server show SERVER_ID -c OS-EXT-SRV-ATTR:host -c status
```

---

## Health Check Reference

`scripts/health-check.sh` performs all checks automatically. Key commands it runs:

```bash
# All OpenStack services
openstack service list
openstack endpoint list | grep public

# Nova hypervisors and capacity
openstack hypervisor list --long
openstack hypervisor stats show

# Nova compute services
openstack compute service list

# Neutron agents
openstack network agent list

# Cinder volume services
openstack volume service list

# Ceph cluster health
ssh 10.0.1.31 "ceph status"
ssh 10.0.1.31 "ceph osd stat"

# MariaDB Galera cluster state
docker exec mariadb mysql -u root -e "SHOW STATUS LIKE 'wsrep_cluster_size'"

# RabbitMQ cluster
docker exec rabbitmq rabbitmqctl cluster_status

# HAProxy backends
curl -s http://10.0.1.100:1984/stats;csv | awk -F, '{print $1,$2,$18}' | column -t
```

**Quick access URLs after health check:**
- Horizon: http://192.168.1.100 (admin / from /etc/kolla/admin-openrc.sh)
- Grafana: http://10.0.1.100:3000 (admin / check passwords.yml for grafana_admin_password)
- HAProxy Stats: http://10.0.1.100:1984/stats
- Prometheus: http://10.0.1.100:9090

---

## Common Issues and Fixes

| Issue | Likely Cause | Fix |
|-------|-------------|-----|
| `kolla-ansible prechecks` fails on disk space | `/var/lib/docker` < 200 GB | Expand volume or clean old images: `docker image prune -a` |
| nova-compute timeout during deploy | Container crash on compute node | `ssh compute01 "docker logs nova_compute"` + check libvirt |
| Ceph `HEALTH_WARN clock skew` | NTP drift > 0.05s | `ansible all -m command -a "chronyc makestep"` |
| MariaDB Galera split-brain | Network partition between controllers | `kolla-ansible -i inventory/multinode mariadb_recovery` |
| RabbitMQ partition detected | Brief network outage | Reset minority node: `docker exec rabbitmq rabbitmqctl stop_app && rabbitmqctl reset && rabbitmqctl start_app` |
| VMs can't get floating IPs | L3 agent down or br-ex misconfigured | `openstack network agent list` → check L3 agent; `ovs-vsctl show` on controller |
| `rbd_secret_uuid` error in Nova logs | Placeholder UUID not replaced | Set real UUID in `config/nova/nova.conf` + `kolla-ansible reconfigure --tags nova` |
| Live migration fails with CPU incompatible | Source/dest compute have different CPUs | Ensure `cpu_allocation_ratio = host-passthrough` — all compute must be same CPU generation |
| Galera node doesn't rejoin after restart | gcache expired (node was offline > gcache/rate) | `docker exec mariadb mysql -e "SET GLOBAL wsrep_provider_options='pc.bootstrap=YES'"` on surviving primary |
| nova-compute can't reach Ceph | Wrong ceph.client.nova.keyring | Check `/etc/kolla/config/nova/` — keyring must match Ceph `client.nova` user |

---

## Useful One-Liners

```bash
# Source admin credentials
source /etc/kolla/admin-openrc.sh

# All running VMs and their hypervisors
openstack server list --all-projects --long -c ID -c Name -c Status -c Host

# Floating IPs and their associations
openstack floating ip list

# Tenant networks and their VXLAN segment IDs
openstack network list --long -c ID -c Name -c "Provider:Segmentation ID" -c "Provider:Network Type"

# OVS flow tables on a compute node (tunnel table)
ssh compute01 "ovs-ofctl dump-flows br-tun | head -30"

# Check which controller holds the VIP
for h in ctrl01 ctrl02 ctrl03; do echo -n "$h: "; ssh $h "ip addr show eno1 | grep 10.0.1.100 || echo no VIP"; done

# Container resource usage on all controllers
ansible control -i inventory/multinode -m command -a "docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'"

# Galera cluster state across all controllers
for ip in 10.0.1.11 10.0.1.12 10.0.1.13; do
  echo "=== $ip ===" && ssh $ip "docker exec mariadb mysql -u root -pPASS -e \"SHOW STATUS LIKE 'wsrep_%'\" 2>/dev/null | grep -E 'wsrep_cluster_size|wsrep_cluster_status|wsrep_ready'"
done

# List all Ceph RBD volumes in pools
ssh storage01 "rbd ls images; rbd ls volumes; rbd ls vms"

# Kolla-ansible reconfigure single node
kolla-ansible -i inventory/multinode reconfigure --limit 10.0.1.11

# Check all kolla container versions
ansible control -i inventory/multinode -m command -a "docker ps --format '{{.Image}}' | sort -u | head -20"
```

---

## Backup / Disaster Recovery

| Component | Backup Method | Frequency |
|-----------|--------------|-----------|
| MariaDB | `mysqldump` or Galera SST (built-in) + external snapshot | Daily |
| Ceph | Ceph pool snapshots, `rbd export` for critical volumes | Per-volume policy |
| Kolla config | Git repo (`globals.yml`, `config/`, `inventory/`) | On every change |
| Credentials | Encrypted backup of `/etc/kolla/passwords.yml` | On every kolla-genpwd |
| VM snapshots | `openstack server image create` → stores in Ceph `images` pool | Per workload SLA |
| Network config | `openstack network list --long` + Neutron DB (covered by MariaDB backup) | With MariaDB |
