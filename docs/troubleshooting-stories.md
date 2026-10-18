# Troubleshooting stories

Real problems, how I narrowed them down, and what fixed them.

---

## 1. "No route to host", but only sometimes

**Symptom.** Docker image pulls and a Home Assistant update failed with `dial tcp …:443: connect: no route to host`, but only intermittently. Home Assistant wouldn't start, because its supervisor insists on updating itself first. Meanwhile the Windows PC could reach the same servers fine.

**Narrowing it down:**
1. **DNS?** No: the names resolved, and the failures were at TCP connect.
2. **A single bad server?** No: a redirect to a different GitHub registry address failed too.
3. **The firewall?** I watched OPNsense's live firewall log while reproducing the failure. The connections were **passed** out of the WAN, so OPNsense wasn't blocking them. The refusal was coming from **beyond** it, from the ISP router.
4. The same log showed hundreds of outbound connections to random home IPs on high ports, which is peer-to-peer traffic. **Firewall → Diagnostics → States**, filtered on one of those IPs, showed the source was the **Docker host**.
5. On the Docker host, `conntrack -L` grouped by source address pointed to one container with **~2,200 connections** (about 40× the next one), and the destination ports confirmed BitTorrent and DHT traffic.

**Cause.** A media "debrid bridge" container was running its own peer-to-peer client, enough connections to fill the ISP router's connection table. Once the table is full, new connections fail at random, whichever device makes them.

**Fix and lesson.** Turn off the feature that made it fetch uncached content itself, or restrict the container to HTTPS only. Longer term, put the ISP router in bridge mode so the firewall holds the connection table. **Lesson:** bandwidth graphs looked fine. The constraint was the *number of connections*, not throughput.

---

## 2. A CDN that crawls on one ISP

**Symptom.** `pip install` and `apt` downloads crawled at about 40 kB/s while everything else was fast.

**Finding.** Both PyPI and `deb.debian.org` are served by the same CDN, which routed badly from this ISP. Testing several mirrors showed others at full speed.

**Fix.** Point `uv` and pip at a fast PyPI mirror (`~/.config/uv/uv.toml`), and use a different Debian mirror. Installs went from minutes to seconds.

---

## 3. Snapshots at the wrong time

**Symptom.** The preview for a "daily at 23:30" snapshot task listed the system time zone as *America/Los_Angeles*.

**Cause.** The NAS had never been set to the local time zone, so every scheduled task (snapshots, scrubs) ran 11 hours off.

**Fix and lesson.** Set the time zone during first setup, and check it on every appliance.

---

## 4. A YouTube downloader stuck at 270 KB/s

**Symptom.** My yt-dlp web front-end downloaded at about 270 KB/s per video, and subtitle downloads failed jobs with HTTP 429.

**Fix.** Download each video as byte-range fragments, with 6 in parallel. Throughput rose to about **2.3 MB/s**. Subtitle failures now become warnings, so they don't fail the whole job.

---

## 5. The backup server that wouldn't answer

**Symptom.** After an upgrade, the backup server VM booted, but its web UI and SSH never started.

**Complication.** A health check run on the NAS itself can't reach its own VM over the bridge.

**Fix.** A cron watchdog on the **Proxmox host** checks the backup server's web UI every 10 minutes. If it stops answering, the watchdog calls a small helper script on the NAS over SSH to restart the VM.
