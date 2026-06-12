# Architecture Overview
## OpenStack 2024.1 Caracal

> **Quick reference:** Everything you need to understand the deployment at a glance.  
> For detailed deep-dives, see the linked documents at the bottom of this page.

---

## Deployment Summary

| Item | Value |
|------|-------|
| **OpenStack release** | 2024.1 (Caracal) |
| **Deployment tool** | Kolla-Ansible |
| **Container base** | Ubuntu 22.04 (source builds) |
| **Total nodes** | 10 (3 ctrl + 4 compute + 3 storage + 1 deploy) |
| **HA** | Yes — Keepalived + HAProxy across 3 controllers |
| **Internal VIP** | 10.0.1.100 |
| **External VIP** | 192.168.1.100 |
| **Internal FQDN** | openstack.internal.example.com |
| **External FQDN** | openstack.example.com |
| **TLS** | Disabled (termination at HAProxy — enable via `kolla_enable_tls_*`) |
| **Storage backend** | External Ceph RBD (3-node, not Kolla-managed) |
| **Hypervisor** | KVM + libvirt, cpu_mode=host-passthrough |
| **Networking** | Neutron ML2/OVN + Geneve overlay, distributed L3 |

---

## Node Roster

| Node | IP | Hardware | Role |
|------|----|----------|------|
| deploy01 | 10.0.1.10 | — | Kolla-Ansible deploy node (Ansible only, no containers) |
| ctrl01 | 10.0.1.11 | 16c / 64GB / 2×480GB SSD / 4 NICs | Controller — HA, all APIs, MariaDB, RabbitMQ |
| ctrl02 | 10.0.1.12 | 16c / 64GB / 2×480GB SSD / 4 NICs | Controller — HA, all APIs, MariaDB, RabbitMQ |
| ctrl03 | 10.0.1.13 | 16c / 64GB / 2×480GB SSD / 4 NICs | Controller — HA, all APIs, MariaDB, RabbitMQ |
| compute01 | 10.0.1.21 | 32c / 256GB / 2×480GB SSD / 4 NICs | KVM hypervisor, Nova-Compute, Neutron OVN |
| compute02 | 10.0.1.22 | 32c / 256GB / 2×480GB SSD / 4 NICs | KVM hypervisor, Nova-Compute, Neutron OVN |
| compute03 | 10.0.1.23 | 32c / 256GB / 2×480GB SSD / 4 NICs | KVM hypervisor, Nova-Compute, Neutron OVN |
| compute04 | 10.0.1.24 | 32c / 256GB / 2×480GB SSD / 4 NICs | KVM hypervisor, Nova-Compute, Neutron OVN |
| storage01 | 10.0.1.31 | 8c / 32GB / 1×SSD + 3×4TB NVMe / 4 NICs | Ceph OSD, Cinder-Volume |
| storage02 | 10.0.1.32 | 8c / 32GB / 1×SSD + 3×4TB NVMe / 4 NICs | Ceph OSD, Cinder-Volume |
| storage03 | 10.0.1.33 | 8c / 32GB / 1×SSD + 3×4TB NVMe / 4 NICs | Ceph OSD, Cinder-Volume |

**Compute capacity:** 4 nodes × 32 cores = 128 physical cores → up to **512 vCPUs** (4× overcommit)  
**RAM capacity:** 4 nodes × 256GB − 4×2GB reserved = ~1 TB available to VMs  
**Storage (Ceph):** 3 nodes × 3× NVMe = 9 OSDs × 4TB = ~36TB raw  

---

## Enabled OpenStack Services

| Service | API Port | Purpose |
|---------|----------|---------|
| Keystone | 5000 | Identity, tokens, service catalog |
| Nova | 8774 | Compute (KVM), VM lifecycle, live migration |
| Neutron | 9696 | Networking (ML2/OVN, Geneve, distributed L3, floating IPs) |
| Glance | 9292 | VM image registry (Ceph RBD backend) |
| Cinder | 8776 | Block volumes (Ceph RBD backend) |
| Heat | 8004 | Orchestration via YAML templates |
| Barbican | 9311 | Secret/key management |
| Horizon | 80 | Web dashboard |
| Prometheus | 9090 | Metrics scraping and alerting |
| Grafana | 3000 | Metrics dashboards |

**Disabled services:** Designate, Octavia, Magnum, Manila, Ironic, Trove, Zun, OpenSearch

---

## Quick-Reference Endpoints

All endpoints reach the active controller via the VIP. HAProxy load-balances across all three.

| Service | URL | Notes |
|---------|-----|-------|
| **Horizon Dashboard** | http://192.168.1.100 | Main user interface |
| **Keystone API** | http://10.0.1.100:5000/v3 | Identity / tokens |
| **Nova API** | http://10.0.1.100:8774/v2.1 | Compute |
| **Neutron API** | http://10.0.1.100:9696 | Networking |
| **Glance API** | http://10.0.1.100:9292 | Images |
| **Cinder API** | http://10.0.1.100:8776/v3 | Block storage |
| **Heat API** | http://10.0.1.100:8004/v1 | Orchestration |
| **Barbican API** | http://10.0.1.100:9311 | Secrets |
| **noVNC Console** | http://10.0.1.100:6080/vnc_lite.html | VM browser console |
| **Grafana** | http://10.0.1.100:3000 | Metrics dashboards |
| **Prometheus** | http://10.0.1.100:9090 | Metrics query |
| **HAProxy Stats** | http://10.0.1.100:1984/stats | LB backend health |

To use CLI: `source /etc/kolla/admin-openrc.sh`

---

## Physical Network Summary

| Network | Subnet | Interface | Purpose |
|---------|--------|-----------|---------|
| Management/API | 10.0.1.0/24 | eno1 | All OpenStack API traffic, SSH, Ansible, Galera, RabbitMQ |
| External/Provider | untagged (no IP) | eno2 | Neutron br-ex, floating IPs, VM north-south traffic |
| Storage/VXLAN | 10.0.2.0/24 | eno3 | Ceph public network, VXLAN VTEP, live migration |
| Ceph Replication | 10.0.3.0/24 | eno4 | OSD-to-OSD replication (see note below) |

> ⚠️ **Note:** `globals.yml` sets `cluster_interface: "eno3"` (same as `storage_interface`).  
> The eno4/10.0.3.0/24 network is wired but not currently used by Kolla.  
> To isolate Ceph replication traffic, change `cluster_interface: "eno4"` and redeploy.

---

## High-Availability Summary

```
Internet / User
      │
      ▼
192.168.1.100 (External VIP)
      │
      ├─── HAProxy on ctrl01  (Keepalived MASTER)
      ├─── HAProxy on ctrl02  (Keepalived BACKUP)
      └─── HAProxy on ctrl03  (Keepalived BACKUP)
                │
                ▼
      10.0.1.100 (Internal VIP)
         Round-robin to ctrl01:PORT, ctrl02:PORT, ctrl03:PORT
```

**VIP failover time:** < 2 seconds (Keepalived VRRP advertisement interval: 1s)  
**DB failover:** Automatic Galera resync when a controller rejoins  
**MQ failover:** Automatic RabbitMQ mirror-queue re-election  

---

## Storage Architecture Summary

```
Nova-Compute ─────────────────────────────────┐
Glance-API   ──→  Ceph RBD (eno3 network)  ───┤── External Ceph Cluster
Cinder-Volume ────────────────────────────────┘    (storage01-03, 10.0.1.31-33)

Ceph Pools:
  images   ← Glance (VM images)
  volumes  ← Cinder (block volumes)
  vms      ← Nova (ephemeral disks — VM disk lives in Ceph, not on compute node)
```

Because Nova ephemeral disks are in Ceph, live migration moves **only RAM state** — not disk — which means sub-second disk migration and < 500ms VM downtime.

---

## Documentation Index

| Document | What it covers |
|----------|---------------|
| [Service Placement](service-placement.md) | Which container runs on which node |
| [Network Topology](network-topology.md) | 4 physical networks, Geneve overlay (OVN), provider networks, traffic flows |
| [HA & Load Balancer](ha-and-loadbalancer.md) | Keepalived VIP, HAProxy backends, Galera, RabbitMQ cluster |
| [Storage Architecture](storage-architecture.md) | Ceph integration — pools, keyrings, live migration |
| [Operational Runbook](operational-runbook.md) | Deploy steps, Day-2 ops, health check, troubleshooting |
| [Diagrams](diagrams/README-diagrams.md) | Mermaid diagrams (GitHub-rendered) |
| [Interactive Diagram](diagrams/topology.html) | Visual HTML poster — open in browser |
