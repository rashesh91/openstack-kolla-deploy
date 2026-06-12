# OpenStack Private Cloud — Kolla-Ansible

**Lintel Labs @ CtrlS Data Center** · OpenStack 2024.1 Caracal · 3+4+3 HA Cluster

Production-grade HA OpenStack deployment using **Kolla-Ansible** on bare metal. Built to host AI/ML workloads internally — full data sovereignty, GPU control, no cloud egress costs.

**OpenStack release:** 2024.1 (Caracal)

---

## Architecture

```
 CtrlS Data Center — Lintel Labs
 ═══════════════════════════════════════════════════════════════════════
 eno1  Management / API  ·  10.0.1.0/24
 ─────────────────────────────────────────────────────────────────────
   deploy01(.10)
   ctrl01(.11) ─── ctrl02(.12) ─── ctrl03(.13)
   compute01(.21) ─ compute02(.22) ─ compute03(.23) ─ compute04(.24)
   storage01(.31) ─ storage02(.32) ─ storage03(.33)
   ⚡ Internal VIP: 10.0.1.100  │  🌐 External VIP: 192.168.1.100
 ═══════════════════════════════════════════════════════════════════════
 eno2  External / Provider  ·  untagged  ·  br-ex
 ─────────────────────────────────────────────────────────────────────
   ctrl01-03 + compute01-04  →  physnet1  →  Floating IPs 192.168.100.x
 ═══════════════════════════════════════════════════════════════════════
 eno3  Storage + VXLAN VTEP  ·  10.0.2.0/24
 ─────────────────────────────────────────────────────────────────────
   ctrl01(.11) ─── ctrl02(.12) ─── ctrl03(.13)   [VTEP + Ceph clients]
   compute01(.21) ─ compute02(.22) ─ compute03(.23) ─ compute04(.24) [VTEP]
   storage01(.31) ─ storage02(.32) ─ storage03(.33)  [Ceph OSD public]
   ╌╌╌╌╌ VXLAN overlay VNI 1-65535 UDP/4789 ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 ═══════════════════════════════════════════════════════════════════════
 eno4  Ceph Replication  ·  10.0.3.0/24  (cabled, cluster_interface=eno3)
 ─────────────────────────────────────────────────────────────────────
   storage01(.31) ─ storage02(.32) ─ storage03(.33)
 ═══════════════════════════════════════════════════════════════════════

 ┌─────────────────── Controllers ───────────────────────┐
 │  ctrl01/02/03  (16c / 64GB each)                      │
 │  HAProxy+Keepalived · MariaDB Galera · RabbitMQ ×3    │
 │  Keystone · Nova · Neutron · Glance · Cinder · Heat   │
 │  Barbican · Horizon · Prometheus · Grafana            │
 └───────────────────────────────────────────────────────┘
 ┌─────────────────── Compute ────────────────────────────┐
 │  compute01-04  (32c / 256GB each, 512 vCPU total)      │
 │  nova-compute (KVM/libvirt) · neutron-ovs-agent        │
 └────────────────────────────────────────────────────────┘
 ┌─────────────────── Storage ────────────────────────────┐
 │  storage01-03  (8c / 32GB · 3×4TB NVMe each)           │
 │  Ceph OSD (9 total, 36TB raw, ~12TB usable)            │
 │  cinder-volume (pools: images · volumes · vms)         │
 └────────────────────────────────────────────────────────┘
```

| Node group  | Count | IPs | Role |
|-------------|-------|-----|------|
| Controllers | 3 | 10.0.1.11–13 | API, DB, MQ, Ceph Mon — HA via Keepalived + HAProxy |
| Compute     | 4 | 10.0.1.21–24 | KVM hypervisor, Nova Compute, Neutron OVS |
| Storage     | 3 | 10.0.1.31–33 | Ceph OSD (9 OSDs total, ~12TB usable) + Cinder Volume |
| Deploy      | 1 | 10.0.1.10 | Runs kolla-ansible — no OpenStack containers |

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

---

## Diagrams & Documentation

| Document | Description |
|----------|-------------|
| [Architecture Overview](docs/architecture-overview.md) | Node roster, endpoints, service summary, network overview |
| [Network Topology](docs/network-topology.md) | 4 physical networks, VXLAN overlay, provider net, traffic flows |
| [HA & Load Balancer](docs/ha-and-loadbalancer.md) | Keepalived VRRP, HAProxy ports, Galera, RabbitMQ, failure scenarios |
| [Storage Architecture](docs/storage-architecture.md) | Ceph pools, keyring placement, live migration, overcommit ratios |
| [Service Placement](docs/service-placement.md) | Per-node container inventory — every service on every node |
| [Operational Runbook](docs/operational-runbook.md) | Deploy procedure, Day-2 ops, health checks, common fixes |
| [Mermaid Diagrams](docs/diagrams/README-diagrams.md) | 5 GitHub-rendered diagrams (topology, networks, HA, service deps, storage) |
| [Interactive Visual](docs/diagrams/topology.html) | Single-file HTML poster — open in browser, works offline |

**Open the interactive diagram locally:**
```bash
python3 -m http.server 8090 --directory docs/diagrams/
# then visit http://localhost:8090/topology.html
```
