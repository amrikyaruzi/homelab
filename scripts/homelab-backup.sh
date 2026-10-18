#!/bin/bash
# =============================================================================
# homelab-backup.sh - nightly config backup of the SheyKia homelab to GitHub
#
# Runs on the Proxmox host (10.10.10.50). Collects:
#   - Proxmox: LXC/VM configs, storage/network/fstab, snippets, own scripts
#   - Docker VM (10.10.10.26): compose files, Homepage config, small app code
#   - Selected files from inside LXC containers (via pct, no SSH needed)
# then REDACTS secrets, SCANS for anything that still looks secret, and commits
# + pushes to a PRIVATE GitHub repo. If the scan finds something, nothing is
# committed and the log says which file and line to look at.
# Also copies the *arr apps' own backup zips to TrueNAS (see APP_BACKUP_DIR).
#
# Usage:  /root/homelab-backup.sh             collect, check, commit, push
#         /root/homelab-backup.sh --dry-run   collect + check, show changes, no commit
# Cron:   /etc/cron.d/homelab-backup  (02:30 daily, before the 03:00 PBS backup)
# Log:    /var/log/homelab-backup.log
# =============================================================================
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin   # cron has a short PATH (pct lives in /usr/sbin)

REPO="${REPO:-/root/homelab-config}"
DOCKER_HOST="${DOCKER_HOST_SSH:-root@10.10.10.26}"
DOCKER_KEY="${DOCKER_KEY:-/root/.ssh/docker_backup}"
DOCKER_ROOT="/opt/docker"
GIT_NAME="Your Name"
GIT_EMAIL="you@example.com"
KUMA_PUSH_URL="${KUMA_PUSH_URL:-}"   # optional Uptime Kuma "Push" monitor URL
LOCAL_DOCKER_DIR="${LOCAL_DOCKER_DIR:-}"   # testing only: read Docker files locally

# App backups (NOT GitHub - they contain API keys): the weekly backup zips that
# Sonarr/Radarr/Lidarr/Prowlarr/Readarr make themselves are copied to TrueNAS.
# Set APP_BACKUP_DIR="" to switch this off. Copying only happens when
# APP_BACKUP_MOUNT is really mounted, so a dead NFS share never fills this disk.
APP_BACKUP_MOUNT="${APP_BACKUP_MOUNT-/mnt/fastfiles}"
APP_BACKUP_DIR="${APP_BACKUP_DIR-/mnt/fastfiles/homelab-backups/arr}"
APP_BACKUP_DAYS="${APP_BACKUP_DAYS:-35}"   # keep zips this many days

# Files inside containers worth keeping:  "CTID:/path/in/container"
CONTAINER_FILES=(
  "133:/etc/systemd/system/jupyterlab.service"
  "133:/home/amrikyaruzi/.config/uv/uv.toml"
  "124:/etc/systemd/system/godseye.service"
  "129:/etc/apt/sources.list.d/cran.list"
)

# Proxmox host files
HOST_FILES=(
  /etc/pve/storage.cfg /etc/pve/datacenter.cfg /etc/pve/jobs.cfg /etc/pve/vzdump.cron
  /etc/network/interfaces /etc/fstab /etc/hosts
  /etc/cron.d/pbs-watchdog /etc/cron.d/homelab-backup
  /etc/sysctl.d/99-swappiness.conf
  /root/pbs-watchdog.sh /root/backup-pve-config.sh /root/homelab-backup.sh
)

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

log() { echo "$(date '+%F %T') $*"; }
die() { log "ERROR: $*"; exit 1; }

# --------------------------------------------------------------------- collect
collect_proxmox() {
  mkdir -p "$REPO/proxmox/lxc" "$REPO/proxmox/qemu-server" "$REPO/proxmox/host" "$REPO/proxmox/snippets"
  cp /etc/pve/lxc/*.conf "$REPO/proxmox/lxc/" 2>/dev/null || log "warn: no LXC configs found"
  cp /etc/pve/qemu-server/*.conf "$REPO/proxmox/qemu-server/" 2>/dev/null || log "warn: no VM configs found"
  cp /var/lib/vz/snippets/*.sh "$REPO/proxmox/snippets/" 2>/dev/null || true
  for f in "${HOST_FILES[@]}"; do
    [ -f "$f" ] && cp "$f" "$REPO/proxmox/host/$(basename "$f")"
  done
  command -v pveversion >/dev/null && pveversion -v > "$REPO/proxmox/host/pveversion.txt" 2>/dev/null
  return 0
}

# Small text files only; heavy/data folders are skipped entirely.
DOCKER_FIND='find . \( -path ./immich/library -o -path ./immich/postgres -o -path ./ytdl/downloads -o -path ./ytdl/data -o -name node_modules -o -name .git -o -name __pycache__ -o -name data -o -name cache -o -name logs -o -name backups -o -name Definitions -o -name Indexers \) -prune -o -type f -size -512k ! -iname "*secret*" ! -name ".env*" \( -name "*.yml" -o -name "*.yaml" -o -name Dockerfile -o -name "*.py" -o -name "*.html" -o -name "*.sh" -o -name "*.md" -o -name "*.toml" -o -name "*.conf" -o -name "requirements*.txt" \) -print0'

collect_docker() {
  mkdir -p "$REPO/docker"
  if [ -n "$LOCAL_DOCKER_DIR" ]; then
    (cd "$LOCAL_DOCKER_DIR" && eval "$DOCKER_FIND" | tar --null -cf - -T -) | tar -xf - -C "$REPO/docker"
    return
  fi
  if ! ssh -i "$DOCKER_KEY" -o BatchMode=yes -o ConnectTimeout=10 "$DOCKER_HOST" \
        "cd $DOCKER_ROOT && $DOCKER_FIND | tar --null -cf - -T -" | tar -xf - -C "$REPO/docker"; then
    die "could not copy files from the Docker VM ($DOCKER_HOST) - nothing committed"
  fi
}

# Copies the apps' own backup zips (e.g. sonarr/config/Backups/scheduled/*.zip)
# from the Docker VM to TrueNAS, keeping the folder layout. Never fatal.
copy_app_backups() {
  [ -n "$APP_BACKUP_DIR" ] || return 0
  if [ -n "$APP_BACKUP_MOUNT" ] && ! mountpoint -q "$APP_BACKUP_MOUNT"; then
    log "warn: $APP_BACKUP_MOUNT is not mounted - app backups not copied"; return 0
  fi
  mkdir -p "$APP_BACKUP_DIR" && chmod 700 "$APP_BACKUP_DIR" || { log "warn: cannot create $APP_BACKUP_DIR"; return 0; }
  local find_zips="find . -path '*/Backups/*' -name '*.zip' -size -500M -mtime -$APP_BACKUP_DAYS -print0"
  local ok=1
  if [ -n "$LOCAL_DOCKER_DIR" ]; then
    (cd "$LOCAL_DOCKER_DIR" && eval "$find_zips" | tar --null -cf - -T -) |
      tar -xf - -C "$APP_BACKUP_DIR" --skip-old-files --no-same-owner || ok=0
  else
    ssh -i "$DOCKER_KEY" -o BatchMode=yes -o ConnectTimeout=10 "$DOCKER_HOST" \
        "cd $DOCKER_ROOT && $find_zips | tar --null -cf - -T -" |
      tar -xf - -C "$APP_BACKUP_DIR" --skip-old-files --no-same-owner || ok=0
  fi
  [ $ok -eq 1 ] || log "warn: copying app backups from the Docker VM failed"
  find "$APP_BACKUP_DIR" -name '*.zip' -mtime +"$APP_BACKUP_DAYS" -delete 2>/dev/null
  find "$APP_BACKUP_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null
  log "App backups: $(find "$APP_BACKUP_DIR" -name '*.zip' | wc -l) zip files, $(du -sh "$APP_BACKUP_DIR" | cut -f1) in $APP_BACKUP_DIR"
}

collect_containers() {
  command -v pct >/dev/null || return 0
  mkdir -p "$REPO/containers"
  for item in "${CONTAINER_FILES[@]}"; do
    id="${item%%:*}"; path="${item#*:}"
    out="$REPO/containers/ct${id}$(echo "$path" | tr '/' '_')"
    if ! pct exec "$id" -- cat "$path" > "$out" 2>/dev/null; then
      rm -f "$out"; log "warn: skipped CT $id $path (stopped or missing)"
    fi
  done
}

# ---------------------------------------------------------------------- redact
# Replaces the VALUE of any key that looks secret (password, token, api key...)
# with <redacted>, keeps ${VAR} / {{VAR}} references, and strips user:pass@ from URLs.
redact() {
  find "$REPO/proxmox" "$REPO/docker" "$REPO/containers" -type f 2>/dev/null -print0 |
  xargs -0 -r perl -pi -e '
    s{^(\s*-?\s*["\x27]?[\w.\-\\]*(?:pass(?:word|wd|phrase)?|secret|token|api[_\-]?key|apikey|network_key|private[_\-]?key|auth[_\-]?key|access[_\-]?key|credential|pre_shared_key|[_\-]key)[\w.\-]*["\x27]?\s*[:=]\s*)(?!["\x27]?(?:\$\{|\{\{|<redacted>))(\S.*)$}{$1<redacted>}i;
    s{^(\s*-?\s*["\x27]?(?:key|pw|psk)["\x27]?\s*[:=]\s*)(?!["\x27]?(?:\$\{|\{\{|<redacted>))(\S.*)$}{$1<redacted>}i;
    s{(\w+://)[^/\s:@]+:[^/\s@]+@}{$1<redacted>@}g;
  '
  # YAML secrets written as a list on the following lines, e.g. zigbee2mqtt:
  #   network_key:
  #     - 12
  #     - 34        -> every item becomes "- <redacted>"
  find "$REPO/docker" "$REPO/containers" -type f \( -name "*.yml" -o -name "*.yaml" \) 2>/dev/null -print0 |
  xargs -0 -r perl -0777 -pi -e '
    s{^(\s*[\w.\-]*(?:pass(?:word|wd)?|secret|token|api[_\-]?key|apikey|[_\-]key|ext_pan_id)\s*:[ \t]*\n)((?:[ \t]*-[ \t]*[^\n]*\n)+)}{
      my ($head, $list) = ($1, $2); $list =~ s/^([ \t]*-[ \t]*).*$/$1<redacted>/mg; $head . $list }gmei;
  '
}

# ------------------------------------------------------------------------ scan
# Last line of defence: refuse to commit anything that still looks like a secret.
# Lines can be allow-listed by putting a fixed piece of text in $REPO/.scan-allow
scan() {
  local hits
  # One PCRE pattern: private keys | GitHub | AWS | Slack | OpenAI-style |
  # any 40+ character token that mixes letters AND digits (so "-----" divider
  # lines and long plain words don't count).
  local pat='-----BEGIN [A-Z ]*PRIVATE KEY-----'
  pat+='|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}'
  pat+='|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9_-]{20,}'
  pat+='|(?<![A-Za-z0-9+/_.-])(?=[A-Za-z0-9+/_-]*[0-9])(?=[A-Za-z0-9+/_-]*[A-Za-z])[A-Za-z0-9+/_-]{40,}={0,2}(?![A-Za-z0-9+/_.-])'
  hits=$(cd "$REPO" && grep -rnIP -e "$pat" proxmox docker containers manual 2>/dev/null |
    grep -vE 'sha(1|256|384|512)[:@-]|@sha256|integrity=|<redacted>' |
    { if [ -s .scan-allow ]; then grep -vFf .scan-allow; else cat; fi } || true)
  if [ -n "$hits" ]; then
    log "STOPPED: possible secrets found - nothing committed. Check these lines:"
    # show the full file name and line, but mask long values in the text
    echo "$hits" | perl -pe 's{^([^:]*:\d+:)(.*)$}{my ($w, $t) = ($1, $2);
      $t =~ s/([A-Za-z0-9+\/_-]{4})[A-Za-z0-9+\/_-]{12,}/$1.../g; "    $w " . substr($t, 0, 120)}e'
    log "Fix the file (or add a harmless line's text to $REPO/.scan-allow) and run again."
    return 1
  fi
  return 0
}

# ----------------------------------------------------------------- repo setup
init_files() {
  [ -f "$REPO/.gitignore" ] || cat > "$REPO/.gitignore" <<'EOF'
# Never commit secrets or data
.env
*.env
.env.*
*.key
*.pem
id_*
*.db
*.sqlite*
*secret*
EOF
  [ -f "$REPO/README.md" ] || cat > "$REPO/README.md" <<'EOF'
# SheyKia homelab - configuration backup (private)

Written nightly by `/root/homelab-backup.sh` on the Proxmox host. Secrets are
replaced with `<redacted>`; real values live in `.env` files and the password
manager. This is the *recipe*; Proxmox Backup Server holds the full machines.

| Folder | Contents |
|---|---|
| `proxmox/lxc`, `proxmox/qemu-server` | container and VM configs (`/etc/pve/...`) |
| `proxmox/host` | storage, network, fstab, cron jobs, own scripts, versions |
| `proxmox/snippets` | hookscripts (e.g. the Real-Debrid mount wait) |
| `docker/` | Docker VM `/opt/docker`: compose files, Homepage config, app code |
| `containers/` | files from inside LXCs (service units, settings) |
| `manual/` | anything added by hand (HA dashboards, notes) - never touched by the script |

Restore a file: copy it back to its original path and fill in the
`<redacted>` values from the password manager / `.env` files.
EOF
  mkdir -p "$REPO/manual"
  [ -f "$REPO/manual/.keep" ] || touch "$REPO/manual/.keep"
}

# ------------------------------------------------------------------------ main
[ -d "$REPO/.git" ] || die "$REPO is not a git repository (clone it first)"
cd "$REPO" || die "cannot enter $REPO"
git config user.name "$GIT_NAME"; git config user.email "$GIT_EMAIL"
git rev-parse --verify -q HEAD >/dev/null || git symbolic-ref HEAD refs/heads/main   # first run: use "main"

if [ $DRY_RUN -eq 0 ] && git rev-parse --verify -q HEAD >/dev/null; then
  git pull -q --rebase || log "warn: git pull failed (offline?) - continuing"
fi

[ $DRY_RUN -eq 0 ] && copy_app_backups   # to TrueNAS, independent of the GitHub part

log "Collecting..."
rm -rf "$REPO/proxmox" "$REPO/docker" "$REPO/containers"   # rebuilt every run
init_files
collect_proxmox
collect_docker
collect_containers
redact
scan || exit 2

git add -A
if git diff --cached --quiet; then
  log "No changes since the last backup."
else
  if [ $DRY_RUN -eq 1 ]; then
    log "Dry run - these files would be committed:"
    git diff --cached --stat | tail -40
    git reset -q
    exit 0
  fi
  git commit -q -m "Backup $(date '+%F %H:%M')" || die "commit failed"
  log "Committed:$(git show --stat --format= HEAD | tail -1)"
fi

if [ $DRY_RUN -eq 0 ]; then
  git push -q -u origin HEAD 2>&1 || die "push to GitHub failed (offline? deploy key?) - will retry next run"
  log "Pushed to GitHub."
  [ -n "$KUMA_PUSH_URL" ] && curl -fsS -m 10 "$KUMA_PUSH_URL?status=up&msg=OK" >/dev/null 2>&1
fi
exit 0
