# Backup strategy

Three layers, each covering what the others can't.

| Layer | What | Where | How often |
|---|---|---|---|
| **Machines** | Every VM and LXC, full image | Proxmox Backup Server (VM on TrueNAS) | Daily 03:00. Kept 7 daily / 4 weekly / 3 monthly |
| **Configuration as code** | VM/LXC configs, host network/storage/cron files, Docker compose files, selected files from inside containers | Private Git repository | Nightly 02:30 |
| **Irreplaceable files** | Family audio recordings, photos, videos | ZFS datasets with snapshots | Daily snapshots, kept 1 year |

## The config-backup script

[`scripts/homelab-backup.sh`](../scripts/homelab-backup.sh) runs on the Proxmox host from cron. It:

1. **Collects** `/etc/pve/lxc/*.conf`, `/etc/pve/qemu-server/*.conf`, storage and network config, fstab, cron jobs and its own scripts. It also pulls small text files (compose files, app configs, code) from the Docker host over SSH, skipping data, cache and media folders.
2. **Redacts secrets.** Any value whose key looks like a password, token, API key or private key becomes `<redacted>`. That includes YAML lists of numbers (e.g. a Zigbee network key) and `user:pass@` in URLs.
3. **Scans for leaks** before committing: private-key headers, GitHub, AWS, Slack and OpenAI-style tokens, and any long random-looking string. If anything is found, **nothing is committed** and the log points to the file and line, with the value masked.
4. **Commits and pushes** only when something changed, using a write-only deploy key.
5. Optionally pings an Uptime Kuma push monitor.

On its first run, the leak scan caught an application password hash that the redaction pattern had missed. The pattern was fixed before anything reached the repository, which is exactly the job of a second safety net.

## Phone recordings → NAS

Near-daily voice recordings are copied from an Android phone to an SMB share every night by a one-way sync with **deletions disabled**, so deleting a file on the phone never deletes the NAS copy. Daily ZFS snapshots then protect against accidental deletion or overwriting on the NAS itself.

## What's next

- An **off-site copy** (encrypted, Backblaze B2) for the irreplaceable data and the PBS datastore. Today everything lives in one house.
- Moving the backup datastore to a larger, dedicated disk.
