# Architecture Diagrams — Lintel Labs @ CtrlS Data Center

GitHub renders these Mermaid diagrams natively in the web UI.  
For an interactive visual version, open [topology.html](topology.html) in a browser.

---

## Diagram A — Node Topology

```mermaid
graph TD
    subgraph CTRLS["🏢 CtrlS Data Center — Lintel Labs"]

        D["🖥️ deploy01\n10.0.1.10\nkolla-ansible\n(no containers)"]

        subgraph CTRL["Controllers — HA Cluster (×3)"]
            C1["ctrl01\n10.0.1.11"]
            C2["ctrl02\n10.0.1.12"]
            C3["ctrl03\n10.0.1.13"]
        end

        IVIP["⚡ Internal VIP\n10.0.1.100\nKeepalived + HAProxy"]
        EVIP["🌐 External VIP\n192.168.1.100\nHorizon + Public APIs"]

        C1 -->|VRRP| IVIP
        C2 -->|VRRP| IVIP
        C3 -->|VRRP| IVIP
        IVIP --> EVIP

        subgraph COMP["Compute Nodes (×4)"]
            N1["compute01\n10.0.1.21\nKVM · OVS"]
            N2["compute02\n10.0.1.22\nKVM · OVS"]
            N3["compute03\n10.0.1.23\nKVM · OVS"]
            N4["compute04\n10.0.1.24\nKVM · OVS"]
        end

        subgraph STOR["Storage Nodes (×3)"]
            S1["storage01\n10.0.1.31\nCeph OSD · Cinder-Vol"]
            S2["storage02\n10.0.1.32\nCeph OSD · Cinder-Vol"]
            S3["storage03\n10.0.1.33\nCeph OSD · Cinder-Vol"]
        end

        CEPH["🗄️ External Ceph Cluster\nPools: images · volumes · vms\nMON: 10.0.1.31-33"]
        S1 & S2 & S3 --- CEPH

    end

    D -->|"ansible SSH\n(deploy time only)"| CTRL & COMP & STOR
    IVIP -->|"Nova API :8774\nNeutron :9696\nGlance :9292"| COMP
    IVIP -->|"Cinder-Vol\nCeph client"| STOR
```

---

## Diagram B — Network Topology (4 Physical Networks)

```mermaid
graph LR
    subgraph MGT["eno1 — Management/API  ·  10.0.1.0/24"]
        MC1(ctrl01\n.11) --- MC2(ctrl02\n.12) --- MC3(ctrl03\n.13)
        MC1 --- MN1(compute01\n.21) & MN2(compute02\n.22)
        MC1 --- MN3(compute03\n.23) & MN4(compute04\n.24)
        MC1 --- MS1(storage01\n.31) & MS2(storage02\n.32) & MS3(storage03\n.33)
        MC1 --- MD(deploy01\n.10)
        MVIP["⚡ VIP .100\nHAProxy\nKeepalived"]
        MC1 & MC2 & MC3 --> MVIP
    end

    subgraph EXT["eno2 — External/Provider  ·  untagged, no IP"]
        EC1(ctrl01\nbr-ex) --- EC2(ctrl02\nbr-ex) --- EC3(ctrl03\nbr-ex)
        EC1 --- EN1(compute01\nbr-ex) & EN2(compute02\nbr-ex)
        EC1 --- EN3(compute03\nbr-ex) & EN4(compute04\nbr-ex)
        FIP["🌐 Floating IPs\n192.168.100.0/24\nphysnet1 flat"]
        EC1 & EC2 & EC3 & EN1 & EN2 & EN3 & EN4 --> FIP
    end

    subgraph STG["eno3 — Storage/Ceph-Public + VXLAN VTEP  ·  10.0.2.0/24"]
        TC1(ctrl01\nVTEP .11) --- TC2(ctrl02\nVTEP .12) --- TC3(ctrl03\nVTEP .13)
        TN1(compute01\nVTEP .21) --- TN2(compute02\nVTEP .22)
        TN3(compute03\nVTEP .23) --- TN4(compute04\nVTEP .24)
        TS1(storage01\nCeph .31) --- TS2(storage02\nCeph .32) --- TS3(storage03\nCeph .33)
        VX["VXLAN Overlay\nVNI 1-65535\nUDP 4789"]
        TC1 & TC2 & TC3 & TN1 & TN2 & TN3 & TN4 -.->|encapsulated| VX
    end

    subgraph REP["eno4 — Ceph Replication  ·  10.0.3.0/24  (cabled, cluster_interface=eno3 currently)"]
        RS1(storage01\n.31) --- RS2(storage02\n.32) --- RS3(storage03\n.33)
    end
```

---

## Diagram C — Service Dependency

```mermaid
graph TD
    HAP["⚖️ HAProxy + Keepalived\nVIP 10.0.1.100"]

    subgraph CTRL_SVC["Controller Services (all 3 controllers)"]
        KS["🔑 Keystone :5000\nIdentity"]
        NOVA_S["🖥️ Nova API :8774\nScheduler · Conductor"]
        NOVA_VNC["🖥️ noVNC :6080\nConsole Proxy"]
        NEU_S["🌐 Neutron :9696\nServer"]
        NEU_AG["🌐 Neutron Agents\nDHCP · L3 · Metadata"]
        GL["📦 Glance :9292\nImages"]
        CIN_S["💾 Cinder :8776\nAPI · Scheduler"]
        HT["🌡️ Heat :8004\nOrchestration"]
        BAR["🔒 Barbican :9311\nSecrets"]
        HZN["🖥️ Horizon :80\nDashboard"]
        DB["🗃️ MariaDB Galera\n3-node sync"]
        MQ["📨 RabbitMQ\n3-node cluster"]
        MC["⚡ Memcached ×3\n:11211"]
        PROM["📊 Prometheus :9090\n+ Grafana :3000"]
    end

    subgraph COMP_SVC["Compute (×4)"]
        NC["🖥️ nova-compute\nKVM/libvirt"]
        OVS["🌐 neutron-ovs-agent\nOVS"]
    end

    subgraph STOR_SVC["Storage (×3)"]
        CV["💾 cinder-volume\nCeph backend"]
    end

    CEPH["🗄️ External Ceph\nimages · volumes · vms"]

    HAP --> KS & NOVA_S & NOVA_VNC & NEU_S & GL & CIN_S & HT & BAR & HZN

    KS --> DB
    NOVA_S --> DB & MQ & MC & NC & GL & NEU_S
    NC --> CEPH
    NEU_S --> DB & MQ & NEU_AG & OVS
    GL --> CEPH & DB
    CIN_S --> DB & MQ & CV
    CV --> CEPH
    HT --> DB & MQ & KS
    BAR --> DB & MQ & KS

    PROM -->|scrapes| NOVA_S & NEU_S & GL & CIN_S & DB & MQ & HAP & CEPH
```

---

## Diagram D — HA / Load Balancer Topology

```mermaid
graph TD
    USER["👤 User / Client"]
    EVIP["🌐 External VIP\n192.168.1.100\nHorizon · Public APIs"]
    IVIP["⚡ Internal VIP\n10.0.1.100\nAll Service APIs"]

    USER --> EVIP

    subgraph KA["Keepalived — VRRP Election on eno1"]
        KA1["ctrl01\nMASTER 🟢"]
        KA2["ctrl02\nBACKUP"]
        KA3["ctrl03\nBACKUP"]
        KA1 -.->|"VRRP advert\nevery 1s"| KA2 & KA3
    end

    EVIP --> KA1
    KA1 -->|"active VIP\nholds both .100 IPs"| IVIP

    subgraph HP["HAProxy Backends — Round-Robin"]
        HP1["ctrl01:PORT"] & HP2["ctrl02:PORT"] & HP3["ctrl03:PORT"]
    end
    IVIP --> HP1 & HP2 & HP3

    subgraph GALERA["MariaDB Galera — Synchronous Replication"]
        G1["ctrl01\n(wsrep primary)"] <-->|wsrep sync| G2["ctrl02"] <-->|wsrep sync| G3["ctrl03"]
    end
    HP1 --> G1 & G2 & G3

    subgraph RABBIT["RabbitMQ — Mirror Queue Cluster"]
        R1["ctrl01"] <-->|mirror queues| R2["ctrl02"] <-->|mirror queues| R3["ctrl03"]
    end
    HP1 --> R1 & R2 & R3
```

---

## Diagram E — Storage Flow (Ceph Integration)

```mermaid
graph LR
    subgraph OS["OpenStack Services"]
        GL["Glance API\n(ctrl01-03)"]
        CIN["Cinder Volume\n(storage01-03)"]
        NOV["Nova Compute\n(compute01-04)"]
    end

    subgraph CEPH["External Ceph Cluster (storage01-03)"]
        direction TB
        IMG["Pool: images\nVM images"]
        VOL["Pool: volumes\nBlock volumes"]
        VMS["Pool: vms\nEphemeral disks"]
        BAK["Pool: backups\nVolume snapshots"]
    end

    GL -->|"ceph.client.glance\nkeyring"| IMG
    CIN -->|"ceph.client.cinder\nkeyring"| VOL
    CIN -->|"backup"| BAK
    NOV -->|"ceph.client.nova\nkeyring"| VMS

    IMG -.->|"copy-on-write\nwhen booting VM"| VMS
```
