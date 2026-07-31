#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION:-v1.1.0}"
REPOSITORY="${REPOSITORY:-guajun/zerotier-moon-endpoint-updater}"
BASE_URL="https://github.com/$REPOSITORY/releases/download/$VERSION"
MOON_JSON="${MOON_JSON:-/var/lib/zerotier-one/moon.json}"

log() {
  printf 'installer: %s\n' "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || die "run as root (for example: curl ... | sudo bash)"
[[ -s "$MOON_JSON" ]] || die "Moon source JSON not found: $MOON_JSON"

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl jq util-linux >/dev/null
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y -q curl jq util-linux
elif command -v yum >/dev/null 2>&1; then
  yum install -y -q curl jq util-linux
else
  for command in curl jq flock; do
    command -v "$command" >/dev/null 2>&1 || die "install $command first"
  done
fi

command -v zerotier-idtool >/dev/null 2>&1 || die "zerotier-idtool is not installed"

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT
for asset in zt-moon-endpoint-update zt-moon-endpoint-updater.service zt-moon-endpoint-updater.timer; do
  curl --fail --silent --show-error --location "$BASE_URL/$asset" -o "$tmp_dir/$asset"
done

install -m 0755 "$tmp_dir/zt-moon-endpoint-update" /usr/local/sbin/zt-moon-endpoint-update
install -m 0644 "$tmp_dir/zt-moon-endpoint-updater.service" /etc/systemd/system/zt-moon-endpoint-updater.service
install -m 0644 "$tmp_dir/zt-moon-endpoint-updater.timer" /etc/systemd/system/zt-moon-endpoint-updater.timer

if [[ ! -e /etc/default/zt-moon-endpoint-updater ]]; then
  cat >/etc/default/zt-moon-endpoint-updater <<EOF
MOON_JSON="$MOON_JSON"
# ROOT_ID=""
# PUBLIC_IP_URL=""
# ENDPOINT_PORT="9993"
# BACKUP_KEEP="10"
# PEER_ROOTS="95bdf667d0=10.244.161.185"
# DEPLOY_TARGETS="root@10.244.161.185"
# SSH_IDENTITY_FILE="/root/.ssh/zt-moon-deploy"
EOF
  chmod 0644 /etc/default/zt-moon-endpoint-updater
fi

systemctl daemon-reload
systemctl enable --now zt-moon-endpoint-updater.timer
systemctl start zt-moon-endpoint-updater.service

log "installed $VERSION"
systemctl --no-pager status zt-moon-endpoint-updater.timer || true
