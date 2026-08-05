# ZeroTier Moon Endpoint Updater

Keeps a ZeroTier Moon's IPv4 `stableEndpoints` entry synchronized with the
server's current public IPv4 address.

The updater runs once shortly after boot and every 15 minutes afterward. It
only regenerates the signed Moon world and restarts ZeroTier when the public IP
changes. The original signing key is preserved, and the last ten source JSON
files are backed up locally.

It can also maintain a shared, multi-root world. A signing primary asks each
peer root to report its own public IPv4 address over SSH, then deploys the same
signed world to those roots. This remains self-healing when a peer root's old
Moon endpoint is stale and the peer can only be reached through a relay.

The repository also includes a manual Windows diagnostic that distinguishes
official Planet reachability from Moon endpoint, general Internet, and local
UDP failures.

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
# PEER_SSH_TARGETS="95bdf667d0=root@10.244.161.185"
# PEER_PUBLIC_IP_URL="https://api.ipify.org"
# DEPLOY_TARGETS="root@10.244.161.185"
# SSH_IDENTITY_FILE="/root/.ssh/zt-moon-deploy"
# SSH_CONNECT_TIMEOUT="30"
```

When `ROOT_ID` is omitted, the updater uses the world ID from `moon.json`.
Alibaba Cloud instance metadata is attempted first. The updater falls back to
the configured `PUBLIC_IP_URL`, then two public HTTPS address services.

`PEER_ROOTS` entries use `root-node-id=ZeroTier-IP`. Add the matching
`PEER_SSH_TARGETS` entry as `root-node-id=user@host`. The signing primary
connects to that host and asks the peer to report its public IPv4 address. The
peer checks Alibaba Cloud instance metadata first, then falls back to
`PEER_PUBLIC_IP_URL`. The signing primary combines the reported address with
`ENDPOINT_PORT`. The peer's own public-IP report is authoritative; discovery
fails without changing the signed world if the report is unavailable.

This avoids a recovery deadlock: after a public IP change, the old Moon path
may no longer be direct, so its observed ZeroTier path cannot be used to learn
the replacement endpoint. It also prevents an ephemeral NAT source port from
being written as a stable Moon endpoint. If no matching `PEER_SSH_TARGETS`
entry exists, the updater retains the legacy direct-path discovery behavior.

When `DEPLOY_TARGETS` is configured, the newly signed world is copied to every
target before the local source is committed. Use a dedicated SSH key in
`SSH_IDENTITY_FILE`. `SSH_CONNECT_TIMEOUT` defaults to 30 seconds so discovery
can still succeed while a peer root is temporarily reachable only by relay.

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

## Independent Worlds

Two independently powered roots can each maintain a single-root world. Keep a
different world ID and signing key on each server, install the updater on both,
and leave `PEER_ROOTS`, `PEER_SSH_TARGETS`, and `DEPLOY_TARGETS` empty. Clients
orbit both world IDs once.

This removes the signing-primary and cross-server SSH dependencies. Keep the
official Planet configured: after a root changes public IP, Planet can help an
existing client reach that root's ZeroTier identity so the client can receive
the newly signed world definition in-band. A network without working Planet
connectivity needs another bootstrap path.

## Windows Path Diagnostic

Run `diagnose-zerotier-path.ps1` from an elevated PowerShell window on a Leaf.
Passive mode does not interrupt ZeroTier:

```powershell
Invoke-WebRequest `
  https://github.com/guajun/zerotier-moon-endpoint-updater/releases/latest/download/diagnose-zerotier-path.ps1 `
  -OutFile .\diagnose-zerotier-path.ps1
Unblock-File .\diagnose-zerotier-path.ps1
```

```powershell
.\diagnose-zerotier-path.ps1 `
  -MoonNodeId aaaaaaaaaa,bbbbbbbbbb `
  -Target 10.0.0.10,10.0.0.11 `
  -PublicFallback 203.0.113.10:22,203.0.113.11:22
```

When a connection is already abnormal, use the active probe. It restarts the
Windows `ZeroTierOneService` once, then watches the clean bootstrap for 20
seconds:

```powershell
.\diagnose-zerotier-path.ps1 -ActiveProbe `
  -MoonNodeId aaaaaaaaaa,bbbbbbbbbb `
  -Target 10.0.0.10,10.0.0.11 `
  -PublicFallback 203.0.113.10:22,203.0.113.11:22 `
  -OutputFile .\zerotier-diagnostic.txt
```

The result is one of:

- `PASS`: an official Planet exchanged traffic during the observation.
- `SUSPECTED_PLANET_FILTER`: ZeroTier UDP reached a Moon after restart, while
  no official Planet replied. This is the strongest evidence for a
  Planet-specific route or filter.
- `ZEROTIER_UDP_UNAVAILABLE`: ordinary connectivity works, but neither Planet
  nor Moon replied. Check PassWall, firewall, NAT, and UDP/9993 first.
- `INCONCLUSIVE`: the passive sample or available evidence cannot isolate the
  fault.

Exit code `0` means `PASS`, `2` means suspected Planet filtering, `3` means an
inconclusive or broader connectivity problem, and `1` means the diagnostic
itself failed. The UDP DNS control only proves that some UDP works; a fresh
Moon path is the stronger comparison because it uses ZeroTier's own protocol.

## Safety

- Updates are serialized with `flock`.
- Discovered addresses are validated as IPv4 addresses.
- The source JSON must contain a signing secret before any update is attempted.
- A new signed world is generated before the live files are replaced.
- Backups are stored in
  `/var/lib/zerotier-one/moon-updater-backups`.

## Tests

Run the endpoint discovery regression test on Linux:

```sh
sudo tests/test-updater.sh
```

Run the diagnostic classification tests on Windows:

```powershell
.\tests\test-diagnose-zerotier-path.ps1
```

## License

MIT
