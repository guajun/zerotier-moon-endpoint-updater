#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run this test as root" >&2; exit 1; }

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT

fake_bin="$test_dir/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *api/token*) printf 'token\n' ;;
  *meta-data/eipv4*) printf '47.57.180.218\n' ;;
  *) printf '47.57.180.218\n' ;;
esac
EOF

cat >"$fake_bin/zerotier-cli" <<'EOF'
#!/usr/bin/env bash
echo "zerotier-cli must not be used when a peer SSH source is configured" >&2
exit 99
EOF

cat >"$fake_bin/zerotier-idtool" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "genmoon" ]] || exit 1
touch 000000a8bb5c9ace.moon
EOF

cat >"$fake_bin/ssh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"curl --fail"* ]]; then
  [[ "${MOCK_SSH_FAIL:-0}" == 0 ]] || exit 255
  printf '120.24.52.245\n'
fi
EOF

cat >"$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$fake_bin/ping" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$fake_bin"/*

moon_json="$test_dir/moon.json"
config_file="$test_dir/updater.conf"
key_file="$test_dir/peer.key"
touch "$key_file"

write_world() {
  cat >"$moon_json" <<'EOF'
{
  "id": "a8bb5c9ace",
  "objtype": "world",
  "worldType": "moon",
  "signingKey_SECRET": "test-secret",
  "roots": [
    {
      "identity": "a8bb5c9ace:0:test",
      "stableEndpoints": ["47.57.180.218/9993"]
    },
    {
      "identity": "95bdf667d0:0:test",
      "stableEndpoints": ["120.77.182.243/52564"]
    }
  ]
}
EOF
}

cat >"$config_file" <<EOF
MOON_JSON="$moon_json"
MOONS_DIR="$test_dir/moons.d"
ROOT_ID="a8bb5c9ace"
ENDPOINT_PORT="9993"
BACKUP_DIR="$test_dir/backups"
LOCK_FILE="$test_dir/updater.lock"
PEER_ROOTS="95bdf667d0=10.244.161.185"
PEER_SSH_TARGETS="95bdf667d0=root@10.244.161.185"
SSH_IDENTITY_FILE="$key_file"
ZEROTIER_SERVICE="test-zerotier.service"
EOF

write_world
PATH="$fake_bin:$PATH" CONFIG_FILE="$config_file" \
  "$repo_dir/zt-moon-endpoint-update"

actual_endpoint="$(jq -r '.roots[] | select(.identity | startswith("95bdf667d0:")) | .stableEndpoints[0]' "$moon_json")"
[[ "$actual_endpoint" == "120.24.52.245/9993" ]] \
  || { echo "unexpected peer endpoint: $actual_endpoint" >&2; exit 1; }

write_world
if PATH="$fake_bin:$PATH" CONFIG_FILE="$config_file" MOCK_SSH_FAIL=1 \
  "$repo_dir/zt-moon-endpoint-update"; then
  echo "updater unexpectedly succeeded when peer self-report failed" >&2
  exit 1
fi

actual_endpoint="$(jq -r '.roots[] | select(.identity | startswith("95bdf667d0:")) | .stableEndpoints[0]' "$moon_json")"
[[ "$actual_endpoint" == "120.77.182.243/52564" ]] \
  || { echo "world changed after discovery failure: $actual_endpoint" >&2; exit 1; }

echo "all updater tests passed"
