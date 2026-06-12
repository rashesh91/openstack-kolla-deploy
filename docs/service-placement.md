# Service Placement — Lintel Labs @ CtrlS Data Center

Which Docker container runs on which physical node.  
Source of truth: `inventory/multinode` + `globals.yml`.

---

## Node Roster

| Hostname | Management IP | Role | OS |
|----------|--------------|------|----|
| deploy01 | 10.0.1.10 | Kolla-Ansible deploy node | Ubuntu 22.04 |
| ctrl01 | 10.0.1.11 | Controller (HA) | Ubuntu 22.04 |
| ctrl02 | 10.0.1.12 | Controller (HA) | Ubuntu 22.04 |
| ctrl03 | 10.0.1.13 | Controller (HA) | Ubuntu 22.04 |
| compute01 | 10.0.1.21 | Compute (KVM) | Ubuntu 22.04 |
| compute02 | 10.0.1.22 | Compute (KVM) | Ubuntu 22.04 |
| compute03 | 10.0.1.23 | Compute (KVM) | Ubuntu 22.04 |
| compute04 | 10.0.1.24 | Compute (KVM) | Ubuntu 22.04 |
| storage01 | 10.0.1.31 | Storage (Ceph OSD) | Ubuntu 22.04 |
| storage02 | 10.0.1.32 | Storage (Ceph OSD) | Ubuntu 22.04 |
| storage03 | 10.0.1.33 | Storage (Ceph OSD) | Ubuntu 22.04 |

**Total: 10 nodes** (1 deploy + 3 controller + 4 compute + 3 storage)

---

## Controller Nodes — ctrl01 / ctrl02 / ctrl03 (identical on all three)

All containers run on all three controllers simultaneously.

### Infrastructure Services
| Container | Purpose |
|-----------|---------|
| `haproxy` | Load balancer — fronts all API ports on both VIPs |
| `keepalived` | VRRP daemon — manages Internal VIP 10.0.1.100 and External VIP 192.168.1.100 |
| `mariadb` | MariaDB + Galera replication (3-node synchronous cluster) |
| `rabbitmq` | Message bus (3-node mirror-queue cluster) |
| `memcached` | Token cache (each controller exposes :11211; all services use all three) |
| `chrony` | NTP synchronisation |

### Identity & Compute API
| Container | Port (on VIP) | Purpose |
|-----------|--------------|---------|
| `keystone` | 5000 | Identity, tokens, service catalog |
| `nova_api` | 8774 | Compute API (v2.1) |
| `nova_conductor` | — | Handles DB calls on behalf of nova-compute |
| `nova_super_conductor` | — | Cell conductor (cell coordination) |
| `nova_scheduler` | — | Placement decisions, filters hypervisors |
| `nova_novncproxy` | 6080 | Browser-based console proxy (noVNC) |

### Networking (Controllers act as Network nodes — no dedicated network node)
| Container | Purpose |
|-----------|---------|
| `neutron_server` | 9696 — Neutron API, subnet/port/router management |
| `neutron_dhcp_agent` | Serves DHCP to tenant VMs (HA: multiple agents) |
| `neutron_l3_agent` | Tenant router, floating IP DNAT/SNAT (HA active/standby) |
| `neutron_metadata_agent` | Forwards cloud-init metadata requests to Nova |
| `openvswitch_db` | OVS database daemon |
| `openvswitch_vswitchd` | OVS forwarding daemon |

### Storage & Orchestration
| Container | Port (on VIP) | Purpose |
|-----------|--------------|---------|
| `glance_api` | 9292 | Image registry API (images stored in Ceph RBD pool: `images`) |
| `cinder_api` | 8776 | Block storage API |
| `cinder_scheduler` | — | Selects the cinder-volume backend for new volumes |
| `heat_api` | 8004 | Orchestration API |
| `heat_api_cfn` | 8000 | CloudFormation-compatible API |
| `heat_engine` | — | Executes stack templates |
| `barbican_api` | 9311 | Secrets management API |
| `barbican_keystone_listener` | — | Listens for Keystone events (user deletion cleanup) |
| `barbican_worker` | — | Async key operations worker |
| `horizon` | 80/443 | Web dashboard |

### Monitoring (on all three controllers via [monitoring] group)
| Container | Port | Purpose |
|-----------|------|---------|
| `prometheus` | 9090 | Metrics collection and alerting |
| `grafana` | 3000 | Metrics dashboards |
| `prometheus_node_exporter` | 9100 | OS/hardware metrics |
| `prometheus_mysqld_exporter` | 9104 | MariaDB/Galera metrics |
| `prometheus_rabbitmq_exporter` | 9419 | RabbitMQ cluster metrics |
| `prometheus_haproxy_exporter` | 9101 | HAProxy backend health metrics |
| `prometheus_openstack_exporter` | 9183 | OpenStack service metrics (Nova, Neutron, etc.) |

> **Note:** `haproxy_stats` is exposed at http://10.0.1.100:**1984**/stats (not via exporter — direct HAProxy page).

**Total containers per controller: ~35**

---

## Compute Nodes — compute01–04 (identical on all four)

| Container | Purpose |
|-----------|---------|
| `nova_compute` | KVM/libvirt hypervisor, runs tenant VMs |
| `nova_libvirt` | libvirtd daemon (Nova delegates VM operations here) |
| `neutron_openvswitch_agent` | OVS agent — programs flow tables for tenant networks |
| `openvswitch_db` | OVS database |
| `openvswitch_vswitchd` | OVS forwarding |
| `prometheus_node_exporter` | OS/hardware metrics |
| `chrony` | NTP sync |

**Total containers per compute node: ~7**

---

## Storage Nodes — storage01–03 (identical on all three)

| Container | Purpose |
|-----------|---------|
| `cinder_volume` | Ceph RBD backend — creates/attaches block volumes (pool: `volumes`) |
| `cinder_backup` | Backs up volumes to Ceph (pool: `backups`) |
| `prometheus_node_exporter` | OS/hardware metrics |
| `prometheus_ceph_mgr_exporter` | Ceph cluster health and OSD metrics |
| `chrony` | NTP sync |

> **Important:** Ceph daemons (MON, MGR, OSD) are **NOT managed by Kolla-Ansible** (`enable_ceph: "no"`).  
> The Ceph cluster is pre-deployed and externally managed. Ceph MON IPs are 10.0.1.31–33.

**Total containers per storage node: ~5**

---

## Deploy Node — deploy01 (10.0.1.10)

No OpenStack containers run here. This node is the Ansible control machine only.

| Tool | Purpose |
|------|---------|
| `kolla-ansible` | Main deployment tool |
| `ansible` | Underlying automation engine |
| `/etc/kolla/globals.yml` | Merged global config |
| `/etc/kolla/passwords.yml` | Generated secrets (kolla-genpwd) |
| `/etc/kolla/config/` | Service config overlays pushed to all nodes |

---

## Service-to-Node Matrix

```
Service              ctrl01  ctrl02  ctrl03  compute01-04  storage01-03
─────────────────────────────────────────────────────────────────────────
HAProxy + Keepalived   ✓       ✓       ✓
MariaDB (Galera)       ✓       ✓       ✓
RabbitMQ               ✓       ✓       ✓
Memcached              ✓       ✓       ✓
Keystone               ✓       ✓       ✓
Nova API/Sched/Cond    ✓       ✓       ✓
Nova Compute                                    ✓ (all 4)
Nova noVNCProxy        ✓       ✓       ✓
Neutron Server         ✓       ✓       ✓
Neutron DHCP/L3/Meta   ✓       ✓       ✓
Neutron OVS Agent      ✓       ✓       ✓         ✓ (all 4)
Glance API             ✓       ✓       ✓
Cinder API/Sched       ✓       ✓       ✓
Cinder Volume                                                  ✓ (all 3)
Cinder Backup                                                  ✓ (all 3)
Heat API/Engine        ✓       ✓       ✓
Barbican               ✓       ✓       ✓
Horizon                ✓       ✓       ✓
Prometheus             ✓       ✓       ✓
Grafana                ✓       ✓       ✓
Node Exporter          ✓       ✓       ✓         ✓ (all 4)    ✓ (all 3)
Ceph MGR Exporter                                              ✓ (all 3)
─────────────────────────────────────────────────────────────────────────
```
