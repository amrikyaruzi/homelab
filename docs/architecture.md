# Architecture

## Hardware

| Machine | Role | Specs |
|---|---|---|
| Dell OptiPlex 5090 SFF | Proxmox VE hypervisor | Intel i5-10500 (6C/12T), 32 GB DDR4, NVMe SSD, Intel UHD 630 (Quick Sync), Fenvi dual 2.5 GbE (Intel i226) |
| HP EliteDesk 800 G4 Tower | TrueNAS SCALE storage | 16 GB RAM, NVMe "fast" pool + 2 × HDD pools |
| Horaco 8-port 2.5G managed switch | Core switch | |
| TP-Link EAP650 | Wi-Fi 6 access point | Managed by a self-hosted Omada controller |
| SMLIGHT SLZB-06U | Zigbee coordinator | Ethernet, Zigbee2MQTT |
| EcoFlow River 3 Plus | Battery backup | Monitored by Home Assistant |

## Network

- **One flat /24 LAN today, with VLANs planned** (cameras first).
- **OPNsense** runs as a VM with three bridges: management, LAN and WAN (to the ISP router).
- **DNS:** clients use AdGuard Home → Unbound on OPNsense → DNS-over-TLS upstreams. Local names resolve under a private `internal` domain through Dnsmasq host overrides.
- **Wi-Fi:** three SSIDs. *Home*, *IoT* (2.4 GHz only, 20 MHz on channel 1, chosen to stay clear of Zigbee channel 25) and *Guest*.
- **Remote access:** a Tailscale subnet router in an LXC advertises the LAN, with split DNS for the `internal` domain. Nothing is port-forwarded.
- **HTTPS inside the LAN:** Nginx Proxy Manager with a wildcard Let's Encrypt certificate obtained by DNS-01 challenge.

## Proxmox layout

| Type | Guests |
|---|---|
| VMs | OPNsense, Home Assistant OS, Debian Docker host |
| LXCs | AdGuard, Omada, Nginx Proxy Manager, Mosquitto, PostgreSQL 17, Stremio, Navidrome, Jellyfin, Paperless-ngx, RustDesk, God's Eye View, RStudio Server, Tailscale, PVE Scripts Local, JupyterLab |

Notes:
- **Jellyfin** is an unprivileged LXC with `/dev/dri` passed through for Quick Sync transcoding.
- **Boot order and start delays** are set so storage-dependent guests start after TrueNAS and the Docker host. A hookscript makes Jellyfin wait for a network mount before starting.
- **IP plan:** infrastructure and services sit in a reserved block, and DHCP hands out a separate range.

## Storage

- **TrueNAS pools:** an NVMe `fast` pool (backup datastore, family videos, recordings, app data) and two HDD pools (media).
- **Shares:** NFS exports are mounted on the Proxmox host and bind-mounted into containers. SMB shares serve phones and the Windows PC.
- **Media library without local downloads:** a debrid bridge exposes cloud-cached content as a FUSE/NFS mount. The *arr apps import **symlinks** into it, so the library uses almost no local disk.
- **Proxmox Backup Server** runs as a VM on TrueNAS, so backups live on a different machine from the hypervisor.

## Docker host

A Debian 13 VM with roughly 28 containers in compose stacks under `/opt/docker`, each service in its own folder. Secrets live in `.env` files (chmod 600), never in the compose files.

## Monitoring

- **Uptime Kuma:** 21 monitors with HTTP, TCP and ping checks, plus status pages.
- **Homepage:** a single dashboard with live widgets for Proxmox, TrueNAS, PBS, OPNsense, AdGuard, Home Assistant and more.
- **Home Assistant:** a "Command Centre" card showing every service's status.
