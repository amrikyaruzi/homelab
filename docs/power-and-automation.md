# Power and home automation

## The problem

The local grid has frequent outages, and voltage can sag to 160–170 V. The lab, the ISP router and the Wi-Fi need to ride through short cuts and **shut down cleanly** during long ones.

## The setup

- **Voltage stabilisers** in front of everything.
- **EcoFlow River 3 Plus** powering the lab (~100 W load), fed through a **Tasmota smart plug** with energy monitoring, so Home Assistant can see whether mains power is present.
- **Home Assistant** reads the EcoFlow's AC input and battery level.

## Graceful shutdown chain

1. Mains power fails. The EcoFlow takes over and Home Assistant notices AC input drop to 0 W.
2. If power is still out when the battery reaches **41%**, Home Assistant runs SSH shell commands in order:
   1. shut down the Windows PC,
   2. shut down **Proxmox**, which stops each guest in its configured order,
   3. shut down **TrueNAS** last, once nothing depends on its shares.
3. When power returns: **"AC power on" BIOS settings** and **Wake-on-LAN** bring the machines back, and Proxmox starts guests in order with start delays, so services that need NFS mounts wait for TrueNAS.

The chain has fired during real outages and shut everything down cleanly.

**Lessons:**
- A guest that ignores the shutdown signal holds up everything. One container took the full 180-second timeout until I gave it its own shorter shutdown timeout.
- The Wi-Fi access point gets its internet through the virtualised firewall, so the Wi-Fi drops whenever Proxmox is off. Plan for this when testing.

## Smart-home highlights

- **Zigbee2MQTT** with an Ethernet coordinator on channel 25, kept away from the 2.4 GHz IoT Wi-Fi on channel 1.
- **Locked-down MQTT broker:** no anonymous access, one user per client.
- **Tasmota plugs:** the kettle (on-device timers), a pressure pump with a **safety auto-off timer** and a "running too long" warning sent to two phones, and the lab's own power feed.
- **Local NTP:** after a fibre outage left plugs at 1970 time with timers that wouldn't fire, every plug now syncs time from the firewall.
- **Dashboards** for power draw, daily energy, pump run-time and every homelab service.
