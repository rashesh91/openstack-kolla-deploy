# OpenStack Private Cloud — Kolla-Ansible

Production-grade HA OpenStack deployment using **Kolla-Ansible** on bare metal. Built to host AI/ML workloads internally — full data sovereignty, GPU control, no cloud egress costs.

**OpenStack release:** 2024.1 (Caracal)

---

## Architecture

```
                    VIP: 10.0.1.100 (Keepalived + HAProxy)
                    ┌──────────┬──────────┬──────────┐
                  ctrl01     ctrl02     ctrl03
               10.0.1.11  10.0.1.12  10.0.1.13
       Keystone · Nova · Neutron · Glance · Cinder · Horizon
       MariaDB (Galera) · RabbitMQ · Memcached · Ceph Mon/MGR

       compute01-04 (10.0.1.21-24)    storage01-03 (10.0.1.31-33)
       Nova Compute (KVM)              Ceph OSD (3x disks each)
       Neutron OVS Agent               Cinder Volume Backend
```

| Node group  | Count | Role |
|-------------|-------|------|
| Controllers | 3 | API, DB, MQ, Ceph Mon — HA via Keepalived + HAProxy |
| Compute     | 4 | KVM hypervisor, Nova Compute, Neutron OVS |
| Storage     | 3 | Ceph OSD (3x disks = 9 OSDs total) |
| Deploy      | 1 | Runs kolla-ansible |

---

## Services

| Service | Purpose |
|---------|---------|
| Keystone | Identity + tokens |
| Nova | Compute (KVM/libvirt) |
| Neutron | Networking (ML2/OVS, VXLAN overlay) |
| Glance | Image registry (stored in Ceph) |
| Cinder | Block volumes (Ceph backend) |
| Horizon | Web dashboard |
| Heat | Orchestration (stack templates) |
| Barbican | Secrets management |
| Prometheus + Grafana | Monitoring |
| OpenSearch | Centralised logging |

---

## Node Requirements

| Role | CPU | RAM | Disks | NICs |
|------|-----|-----|-------|------|
| Controller | 16 cores | 64 GB | 2x 480GB SSD | 4 |
| Compute | 32 cores | 256 GB | 2x 480GB SSD | 4 |
| Storage | 8 cores | 32 GB | 1x SSD + 3x 4TB NVMe | 4 |

**NIC layout per node:**
- `eno1` — Management + API (10.0.1.0/24)
- `eno2` — External/provider (untagged, no IP)
- `eno3` — Storage network, Ceph public (10.0.2.0/24)
- `eno4` — Ceph cluster/replication (10.0.3.0/24)

---

## Quick Start

```bash
# 1. Install kolla-ansible on deploy node
pip install kolla-ansible==2024.1 && kolla-ansible install-deps

# 2. Configure
cp globals.yml /etc/kolla/globals.yml
cp -r config/ /etc/kolla/config/
vim /etc/kolla/globals.yml   # set VIPs, interfaces, Ceph devices
kolla-genpwd

# 3. Deploy
./scripts/deploy.sh

# 4. Post-deploy (networks, flavors, test VM)
source /etc/kolla/admin-openrc.sh
./scripts/post-deploy.sh

# 5. Health check
./scripts/health-check.sh
```

---

## Day-2 Operations

```bash
# Reconfigure one service after config change
kolla-ansible -i inventory/multinode reconfigure --tags nova

# Add a compute node
kolla-ansible -i inventory/multinode bootstrap-servers --limit new-compute05
kolla-ansible -i inventory/multinode deploy --limit new-compute05

# Upgrade release
kolla-ansible -i inventory/multinode pull
kolla-ansible -i inventory/multinode upgrade
```

---

## Common Issues

| Issue | Fix |
|-------|-----|
| Nova-compute timeout | `docker logs nova_compute` on affected host |
| Ceph `HEALTH_WARN clock skew` | `chronyc makestep` on all nodes |
| MariaDB Galera split-brain | `docker exec mariadb galera_recovery` |
| Prechecks fail on disk space | `/var/lib/docker` needs 200 GB+ free |
