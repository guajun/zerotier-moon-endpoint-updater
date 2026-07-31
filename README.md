# ZeroTier Moon Endpoint Updater

Keeps a ZeroTier Moon's IPv4 `stableEndpoints` entry synchronized with the
server's current public IPv4 address.

The updater runs once shortly after boot and every 15 minutes afterward. It
only regenerates the signed Moon world and restarts ZeroTier when the public IP
changes. The original signing key is preserved, and the last ten source JSON
files are backed up locally.

It can also maintain a shared, multi-root world. A signing primary discovers
the direct physical endpoint of peer roots through ZeroTier and deploys the
same signed world to those roots over SSH.

## Requirements

- Linux with systemd
- An existing ZeroTier Moon source file at
  `/var/lib/zerotier-one/moon.json`
- The original `signingKey_SECRET` in that source file
- `zerotier-idtool`

## Install

```sh
curl -fsSL https://github.com/guajun/zerotier-moon-endpoint-updater/releases/latest/download/install.sh | sudo bash
```

The installer runs the updater immediately, then enables the timer.

## Configuration

Edit `/etc/default/zt-moon-endpoint-updater`:

```sh
MOON_JSON="/var/lib/zerotier-one/moon.json"
# ROOT_ID="a8bb5c9ace"
# PUBLIC_IP_URL="https://api.ipify.org"
# ENDPOINT_PORT="9993"
# BACKUP_KEEP="10"
# PEER_ROOTS="95bdf667d0=10.244.161.185"
# DEPLOY_TARGETS="root@10.244.161.185"
# SSH_IDENTITY_FILE="/root/.ssh/zt-moon-deploy"
```

When `ROOT_ID` is omitted, the updater uses the world ID from `moon.json`.
Alibaba Cloud instance metadata is attempted first. The updater falls back to
the configured `PUBLIC_IP_URL`, then two public HTTPS address services.

`PEER_ROOTS` entries use `root-node-id=ZeroTier-IP`. The signing primary pings
that address, reads the peer's active direct endpoint from `zerotier-cli`, and
updates the corresponding root. When `DEPLOY_TARGETS` is configured, the newly
signed world is copied to every target before the local source is committed.
Use a dedicated SSH key in `SSH_IDENTITY_FILE`.

Run an immediate check:

```sh
sudo systemctl start zt-moon-endpoint-updater.service
sudo journalctl -u zt-moon-endpoint-updater.service -n 30 --no-pager
```

Change the interval by overriding the timer:

```sh
sudo systemctl edit zt-moon-endpoint-updater.timer
```

```ini
[Timer]
OnUnitActiveSec=30min
```

## Safety

- Updates are serialized with `flock`.
- Discovered addresses are validated as IPv4 addresses.
- The source JSON must contain a signing secret before any update is attempted.
- A new signed world is generated before the live files are replaced.
- Backups are stored in
  `/var/lib/zerotier-one/moon-updater-backups`.

## License

MIT
