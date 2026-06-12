# HA & Load Balancer

How the three controllers stay highly available: VIP management, load balancing,
database replication, and message queue clustering.

---

## Overview

```
         Client / User
              │
              ▼
    192.168.1.100 (External VIP — Horizon, public APIs)
    10.0.1.100   (Internal VIP — service-to-service)
              │
   ┌──────────┼──────────┐
   ▼          ▼          ▼
 ctrl01     ctrl02     ctrl03
 HAProxy   HAProxy   HAProxy
 (MASTER)  (BACKUP)  (BACKUP)
   │          │          │
   └────── Round-robin to backends ────────┘
              │
   ┌──────────┼──────────┐
   ▼          ▼          ▼
 ctrl01:P   ctrl02:P   ctrl03:P   (P = service port)
```

---

## Keepalived — VIP Management

Keepalived runs on all three controllers and uses **VRRP** (Virtual Router Redundancy Protocol)
to elect a master and move the VIP automatically on failure.

| Parameter | Value |
|-----------|-------|
| VRRP interface | eno1 (management) |
| Internal VIP | 10.0.1.100 |
| External VIP | 192.168.1.100 |
| Advertisement interval | 1 second |
| Failover time | < 2 seconds |
| Priority selection | Automatic (based on node order in inventory) |

**How failover works:**
1. The MASTER controller sends VRRP advertisements every 1 second
2. If a BACKUP misses 3 consecutive advertisements (3s), it declares the master dead
3. The BACKUP with the highest priority takes over the VIP (gratuitous ARP sent)
4. HAProxy on the new master starts accepting connections on the VIP

**Manual VIP check:**
```bash
ip addr show eno1 | grep 10.0.1.100   # Run on each controller — only one should show it
journalctl -u keepalived -n 30          # Keepalived state changes
```

---

## HAProxy — Load Balancer

HAProxy runs on all three controllers. Only the controller holding the VIP accepts external
traffic, but HAProxy itself distributes to all three backend instances of each service.

### Global Settings (from globals.yml)
| Parameter | Value |
|-----------|-------|
| Client timeout | 1 minute |
| Server timeout | 1 minute |
| Connect timeout | 10 seconds |
| Max connections | 10,000 per frontend |
| Stats page | http://10.0.1.100:1984/stats |

### Frontend → Backend Port Map

| Service | Frontend Port (on VIP) | Backend Port (per controller) |
|---------|----------------------|-------------------------------|
| Horizon | 80 | 80 on ctrl01, ctrl02, ctrl03 |
| Keystone | 5000 | 5000 on each controller |
| Nova API | 8774 | 8774 on each controller |
| Neutron | 9696 | 9696 on each controller |
| Glance | 9292 | 9292 on each controller |
| Cinder | 8776 | 8776 on each controller |
| Heat API | 8004 | 8004 on each controller |
| Heat CFN | 8000 | 8000 on each controller |
| Barbican | 9311 | 9311 on each controller |
| noVNC Proxy | 6080 | 6080 on each controller |
| Grafana | 3000 | 3000 on each controller |
| Prometheus | 9090 | 9090 on each controller |
| HAProxy Stats | 1984 | (direct — not load balanced) |

### Health Checks
HAProxy checks each backend every 5 seconds. A backend that fails 3 consecutive checks
is removed from rotation. It re-enters rotation after 3 consecutive successful checks.

```bash
# View live backend state
curl -s http://10.0.1.100:1984/stats;csv | grep -v "#" | column -t -s,

# Or open in browser:
# http://10.0.1.100:1984/stats
```

---

## MariaDB Galera — 3-Node Synchronous DB Cluster

All OpenStack services write to the VIP:3306, which HAProxy routes to any healthy Galera node.
Galera replication is **synchronous** — all nodes always have identical data.

### Configuration
| Parameter | Value | Purpose |
|-----------|-------|---------|
| Cluster nodes | ctrl01, ctrl02, ctrl03 | All three replicate each other |
| Replication protocol | wsrep (Galera) | Synchronous multi-master |
| InnoDB buffer pool | 8192MB | Main memory cache for queries |
| InnoDB log file | 1024MB | Write-ahead log size |
| gcache size | 512MB | Galera replication cache (for re-joining nodes) |
| gcs.fc_limit | 256 | Flow control limit (backpressure) |
| Cluster bind address | eno1 (wsrep_cluster_address) | Replication traffic on management network |

### Galera State Check
```bash
docker exec mariadb mysql -u root -p$(grep 'database_password' /etc/kolla/passwords.yml | awk '{print $2}') \
  -e "SHOW STATUS LIKE 'wsrep_%';"

# Key variables to check:
# wsrep_cluster_size      = 3     (all nodes in cluster)
# wsrep_cluster_status    = Primary
# wsrep_connected         = ON
# wsrep_ready             = ON
# wsrep_local_state_comment = Synced
```

### Recovery: Split-Brain
If a controller loses network and rejoins with a different write set:
```bash
# On the surviving node (has most recent data):
docker exec mariadb mysqladmin -u root -p shutdown
# Edit /var/lib/docker/volumes/mariadb/_data/grastate.dat:
#   Set: safe_to_bootstrap: 1

# Restart the cluster from this node:
docker run --rm -v mariadb:/var/lib/mysql mariadb --wsrep-recover
kolla-ansible -i inventory/multinode mariadb_recovery
```

---

## RabbitMQ — 3-Node Mirror Queue Cluster

All OpenStack services connect to the RabbitMQ VIP. RabbitMQ's mirror queues ensure
every message is replicated to all three nodes before acknowledged to the producer.

### Configuration
| Parameter | Value |
|-----------|-------|
| Cluster nodes | ctrl01, ctrl02, ctrl03 |
| Queue type | Classic (mirrored to all nodes) |
| Erlang cookie | Set in globals.yml `rabbitmq_cluster_cookie` |
| RabbitMQ user | openstack |
| Heartbeat timeout | 60 seconds |
| Heartbeat rate | 2 beats/second |
| Network partition detection | pause_minority |

> ⚠️ **Action required:** Change `rabbitmq_cluster_cookie: "ERLANG_COOKIE_CHANGE_ME"` in  
> globals.yml before deployment. Use: `openssl rand -base64 32 | tr -d '=/+\n' | head -c 32`

### Cluster Health Check
```bash
docker exec rabbitmq rabbitmqctl cluster_status
# Expected: all 3 nodes listed, no network partitions

docker exec rabbitmq rabbitmqctl list_queues name messages consumers
# Verify queues have consumers (services are connected)
```

### Recovery: Network Partition
```bash
# On the minority node (the one that was isolated):
docker exec rabbitmq rabbitmqctl stop_app
docker exec rabbitmq rabbitmqctl reset
docker exec rabbitmq rabbitmqctl start_app
# Then rejoin the cluster — kolla-ansible handles this on redeploy
```

---

## Memcached — Token Cache

One Memcached instance per controller (not clustered). Services use all three endpoints:

```
MEMCACHE_SERVERS = 10.0.1.11:11211;10.0.1.12:11211;10.0.1.13:11211
```

If one controller goes down, services continue using the other two. Memcache is a cache only —
loss of a Memcached node causes a cache miss (tokens re-validated from Keystone) but not
a service outage.

---

## Failure Scenario Table

| Failure | Immediate Impact | Auto-Recovery? | Manual Steps Needed |
|---------|-----------------|----------------|---------------------|
| **1 controller node down** | VIP migrates (< 2s). HAProxy removes dead backends. Nova/Neutron APIs degrade by 1 replica but continue. | ✅ Yes | None — node rejoins Galera/RabbitMQ on restart |
| **2 controllers down** | Galera loses quorum (3→1). RabbitMQ loses quorum. Most APIs fail. | ❌ No | `kolla-ansible mariadb_recovery` + RabbitMQ reset on survivors |
| **VIP switch** | Clients see < 2s blip. Established TCP connections drop. Retry handles this. | ✅ Yes | None |
| **Compute node down** | VMs on that node stop. No live migration from dead node. | ❌ No | `nova evacuate --on-shared-storage INSTANCE_ID` to move to healthy node |
| **Storage node down** | Ceph marks OSDs out. Rebalances to surviving OSDs. | ✅ Yes (Ceph) | Monitor `ceph -w` — wait for rebalance. Data safe if ≥ 2 replicas survive |
| **Network partition (eno1)** | Galera/RabbitMQ may split-brain. VIP may appear on wrong node. | ❌ No | Restore network first, then recover Galera/RabbitMQ |
| **Deploy node down** | No new deployments/reconfigurations. Running cluster unaffected. | N/A | Restore deploy node and re-run with existing /etc/kolla |

---

## Health Check — All HA Components

```bash
# Quick overall check
./scripts/health-check.sh

# Individual component checks:

# Keepalived — who holds the VIP?
ssh ctrl01 'ip addr show eno1' | grep 10.0.1.100

# HAProxy backends
curl -s http://10.0.1.100:1984/stats;csv | awk -F, 'NR>2 {print $1,$2,$18}' | column -t

# Galera cluster size
for ip in 10.0.1.11 10.0.1.12 10.0.1.13; do
  ssh $ip "docker exec mariadb mysql -u root -e \"SHOW STATUS LIKE 'wsrep_cluster_size'\""
done

# RabbitMQ cluster
ssh 10.0.1.11 "docker exec rabbitmq rabbitmqctl cluster_status | grep 'Running Nodes'"

# All OpenStack services
openstack service list && openstack endpoint list | grep -v internal
```
