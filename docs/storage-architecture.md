# Storage Architecture — Lintel Labs @ CtrlS Data Center

---

## Overview

Storage is provided by an **external Ceph cluster** — Kolla-Ansible does **not** manage Ceph  
(`enable_ceph: "no"` in globals.yml). The Ceph cluster is pre-deployed and independently managed.

Three OpenStack services use Ceph RBD as their storage backend:

| OpenStack Service | Ceph Pool | What is stored |
|-------------------|-----------|----------------|
| Glance | `images` | VM images (uploaded or imported) |
| Cinder | `volumes` | Block volumes attached to VMs |
| Cinder Backup | `backups` | Volume snapshots/backups |
| Nova | `vms` | Ephemeral disks (VM boot/data disks) |

---

## Ceph Cluster Layout

| Node | Management IP | Ceph Role | Storage |
|------|--------------|-----------|---------|
| storage01 | 10.0.1.31 | OSD node | 3× 4TB NVMe → 3 OSDs |
| storage02 | 10.0.1.32 | OSD node | 3× 4TB NVMe → 3 OSDs |
| storage03 | 10.0.1.33 | OSD node | 3× 4TB NVMe → 3 OSDs |
| ctrl01–03 | 10.0.1.11–13 | MON + MGR | (No OSD — management only) |

**Total raw capacity:** 9 OSDs × 4TB = ~36TB raw  
**Usable with 3× replication:** ~12TB  
**Ceph MON addresses** (in globals.yml): `10.0.1.31, 10.0.1.32, 10.0.1.33`

> **Note:** Ceph MON and MGR daemons run on the **controller nodes** (10.0.1.11–13),  
> not on the storage nodes. The `ceph_mon_host` IPs (10.0.1.31–33) are the OSD/public IPs  
> used by clients to reach the cluster, not where MON containers run.

---

## Network Paths

```
OpenStack clients (Nova/Glance/Cinder on controllers and compute)
      │
      │  eno3 (10.0.2.0/24) — Ceph public network
      ▼
Ceph OSD nodes (storage01-03)
      │
      │  eno3 (cluster_interface = eno3 currently — same wire as public)
      │  eno4 (10.0.3.0/24) — wired but unused, available for replication isolation
      ▼
Ceph OSD-to-OSD replication
```

**⚠️ cluster_interface = eno3:** Both Ceph client I/O and OSD-to-OSD replication  
currently share the eno3 (10.0.2.0/24) network. To separate them:  
1. Change `cluster_interface: "eno4"` in globals.yml  
2. Run `kolla-ansible -i inventory/multinode reconfigure`  
This will move OSD replication to the dedicated 10.0.3.0/24 network.

---

## Ceph Pool → OpenStack Service Mapping

```
                    ┌─────────────────────────────────────────────┐
                    │           External Ceph Cluster              │
                    │                                              │
                    │  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
                    │  │  images  │  │ volumes  │  │   vms    │  │
                    │  │  (pool)  │  │  (pool)  │  │  (pool)  │  │
                    │  └────┬─────┘  └────┬─────┘  └────┬─────┘  │
                    └───────┼─────────────┼──────────────┼────────┘
                            │             │              │
                        Glance API    Cinder Volume   Nova Compute
                      (ctrl01-03)   (storage01-03)  (compute01-04)
```

### Ceph Client Keyrings Required

Before running `kolla-ansible deploy`, the following files must be manually placed  
on the deploy node at `/etc/kolla/config/`:

```
/etc/kolla/config/
├── nova/
│   ├── ceph.conf                      # Ceph cluster config (mon_host, fsid)
│   └── ceph.client.nova.keyring       # nova client key (pool: vms)
├── cinder/
│   ├── ceph.conf
│   └── ceph.client.cinder.keyring     # cinder client key (pool: volumes)
└── glance/
    ├── ceph.conf
    └── ceph.client.glance.keyring     # glance client key (pool: images)
```

**Generate keyrings on the Ceph admin node:**
```bash
# Create pools
ceph osd pool create images 128
ceph osd pool create volumes 128
ceph osd pool create vms 128
ceph osd pool create backups 64

# Enable RBD application on each pool
rbd pool init images && rbd pool init volumes && rbd pool init vms && rbd pool init backups

# Create Ceph users
ceph auth get-or-create client.glance mon 'profile rbd' osd 'profile rbd pool=images' \
  > /etc/kolla/config/glance/ceph.client.glance.keyring
ceph auth get-or-create client.cinder mon 'profile rbd' \
  osd 'profile rbd pool=volumes, profile rbd pool=vms, profile rbd pool=backups' \
  > /etc/kolla/config/cinder/ceph.client.cinder.keyring
ceph auth get-or-create client.nova mon 'profile rbd' osd 'profile rbd pool=vms' \
  > /etc/kolla/config/nova/ceph.client.nova.keyring
```

---

## Nova Ephemeral Disk in Ceph — Live Migration Advantage

Because Nova is configured to store ephemeral disks in Ceph (`images_type = rbd`, pool `vms`),  
live migration moves **only RAM** between compute nodes. The disk never transfers.

```
Before migration:
  compute01: VM running, RAM in host, disk = Ceph RBD object (vms/vm-uuid)
  compute02: (empty)

During migration:
  1. Nova pre-copies dirty RAM pages: compute01 → compute02 (via eno3)
  2. Final pause: < 500ms (CPU registers + last dirty pages)
  3. VM resumes on compute02

After migration:
  compute01: (empty)
  compute02: VM running, disk = same Ceph RBD object (unchanged, same UUID)
```

**Live migration settings** (nova.conf):
| Setting | Value | Meaning |
|---------|-------|---------|
| `live_migration_downtime` | 500ms | Maximum allowed VM pause |
| `live_migration_completion_timeout` | 800s | Abort if not complete in 13 min |
| `live_migration_progress_timeout` | 150s | Abort if dirty page rate not decreasing |
| Transport | `qemu+ssh://nova@HOST/system` | SSH-based libvirt migration |
| CPU mode | `host-passthrough` | Required: CPU features must match between hosts |

---

## ⚠️ Pre-Deployment TODO: libvirt Secret UUID

`config/nova/nova.conf` contains:

```ini
[libvirt]
rbd_secret_uuid = PUT_LIBVIRT_SECRET_UUID_HERE
```

**You must replace this before deploying.** Steps:

```bash
# 1. Generate a UUID
python3 -c "import uuid; print(uuid.uuid4())"
# e.g., 457eb676-33da-42ec-9a8c-9293d545c337

# 2. Update nova.conf
sed -i 's/PUT_LIBVIRT_SECRET_UUID_HERE/457eb676-33da-42ec-9a8c-9293d545c337/' \
    config/nova/nova.conf

# 3. Create libvirt secret on ALL compute nodes BEFORE kolla-ansible deploy:
#    (This is done automatically by kolla-ansible if the UUID is set correctly)
```

Without the correct UUID, Nova will fail to attach Ceph RBD disks to VMs.

---

## Resource Over-Commit Settings

Configured in `config/nova/nova.conf`:

| Resource | Ratio | Meaning |
|----------|-------|---------|
| CPU | 4.0 | 4 vCPU per physical core. 4 nodes × 32 cores × 4 = **512 vCPU total** |
| RAM | 1.0 | No over-commit. 4 nodes × 254GB usable = **~1 TB** available |
| Disk | 1.5 | Thin provisioning. Actual Ceph pool may hold 1.5× provisioned disk |

**Reserved per compute node:** 2048 MB RAM (for OS/hypervisor — never given to VMs)

---

## Monitoring Storage Health

Prometheus scrapes Ceph MGR exporter on storage01–03 (port 9283).  
Grafana dashboard shows: OSD state, cluster health, pool usage, IOPS, latency.

Quick CLI checks:
```bash
# On any storage node or node with ceph.conf
ceph status                    # Overall cluster health
ceph osd tree                  # OSD layout and state
ceph df                        # Pool usage
rbd ls volumes                 # List Cinder volumes in RBD
rbd info volumes/volume-UUID   # Inspect a specific volume
```
