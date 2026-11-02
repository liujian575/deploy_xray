#!/usr/bin/env bash
# Deploy Xray (VLESS + REALITY + XTLS-Vision) to a remote VPS over SSH,
# then print a Clash Verge (mihomo) profile for it.
#
# Usage (run on your local machine):
#   ./deploy_xray.sh            # asks for the VPS IP and root password
#
# Optional overrides via environment (skip the prompts / change defaults):
#   VPS_HOST=<ip or hostname>   SSHPASS=<password> (empty = SSH key auth)
#   VPS_USER=root  VPS_SSH_PORT=22
#   XRAY_VERSION=26.6.1  XRAY_PORT=443  REALITY_SNI=www.apple.com
#   OUT_FILE=./clash-xray-<host>.yaml

set -euo pipefail

VPS_HOST="${VPS_HOST:-}"
VPS_USER="${VPS_USER:-root}"
VPS_SSH_PORT="${VPS_SSH_PORT:-22}"
XRAY_VERSION="${XRAY_VERSION:-26.6.1}"
XRAY_PORT="${XRAY_PORT:-443}"
REALITY_SNI="${REALITY_SNI:-www.apple.com}"

STEP=0
TOTAL=5
step() { STEP=$((STEP + 1)); printf '\n\033[1;32m==> [%d/%d] %s\033[0m\n' "$STEP" "$TOTAL" "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

# --------------------------------------------------------------------------
step "Checking local prerequisites"
command -v ssh >/dev/null || die "ssh not found"
while [ -z "$VPS_HOST" ]; do
    read -r -p "    VPS IP address (or hostname): " VPS_HOST
    VPS_HOST="$(printf '%s' "$VPS_HOST" | tr -d '[:space:]')"
done
if [ -z "${SSHPASS+x}" ]; then
    read -r -s -p "    SSH password for ${VPS_USER}@${VPS_HOST} (empty = use SSH key): " SSHPASS
    echo
fi
OUT_FILE="${OUT_FILE:-./clash-xray-${VPS_HOST}.yaml}"
PROXY_NAME="xray-reality-${VPS_HOST}"
SSH_OPTS=(-p "$VPS_SSH_PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15
          -o ServerAliveInterval=15)
if [ -n "$SSHPASS" ]; then
    command -v sshpass >/dev/null ||
        die "sshpass not found. Install it: sudo apt install sshpass  (macOS: brew install hudochenkov/sshpass/sshpass)"
    export SSHPASS
    SSH_CMD=(sshpass -e ssh "${SSH_OPTS[@]}" -o PubkeyAuthentication=no
             -o PreferredAuthentications=password,keyboard-interactive)
else
    SSH_CMD=(ssh "${SSH_OPTS[@]}")
fi
info "target : ${VPS_USER}@${VPS_HOST}:${VPS_SSH_PORT}"
info "xray   : v${XRAY_VERSION}, port ${XRAY_PORT}/tcp, REALITY SNI ${REALITY_SNI}"

# --------------------------------------------------------------------------
step "Testing SSH connection"
"${SSH_CMD[@]}" "${VPS_USER}@${VPS_HOST}" 'echo "    connected: $(hostname) / $(uname -sr)"' ||
    die "cannot SSH to ${VPS_USER}@${VPS_HOST}: check the IP and password.
       If the VPS was reinstalled, clear its old host key first: ssh-keygen -R ${VPS_HOST}"

# --------------------------------------------------------------------------
step "Installing and configuring Xray on the VPS"
"${SSH_CMD[@]}" "${VPS_USER}@${VPS_HOST}" bash -s -- "$XRAY_VERSION" "$XRAY_PORT" "$REALITY_SNI" \
    <<'REMOTE' 2>&1 | tee "$LOG" | grep -v '^@@KV '
set -euo pipefail
XRAY_VER="$1"; PORT="$2"; SNI="$3"
rstep() { printf '\033[1;36m    [remote] %s\033[0m\n' "$*"; }
rinfo() { printf '             %s\n' "$*"; }
rdie()  { printf '\033[1;31m    [remote] ERROR: %s\033[0m\n' "$*"; exit 1; }

[ "$(id -u)" = 0 ] || rdie "must run as root"
command -v systemctl >/dev/null || rdie "systemd is required"

rstep "1/9 Detecting system"
OS_NAME="$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown OS}")"
case "$(uname -m)" in
    x86_64|amd64)  ARCH=64 ;;
    aarch64|arm64) ARCH=arm64-v8a ;;
    *) rdie "unsupported architecture $(uname -m)" ;;
esac
rinfo "${OS_NAME}, $(uname -m) -> Xray-linux-${ARCH}.zip"

rstep "2/9 Installing dependencies (curl unzip openssl)"
if command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null
    apt-get install -y -qq curl unzip openssl ca-certificates iproute2 >/dev/null
elif command -v dnf >/dev/null; then
    dnf install -y -q curl unzip openssl ca-certificates iproute >/dev/null
elif command -v yum >/dev/null; then
    yum install -y -q curl unzip openssl ca-certificates iproute >/dev/null
else
    rdie "no supported package manager (apt/dnf/yum)"
fi

rstep "3/9 Downloading Xray v${XRAY_VER}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/Xray-linux-${ARCH}.zip"
rinfo "$URL"
curl -fsSL --retry 3 -o "$TMP/xray.zip" "$URL" || rdie "download failed"
if curl -fsSL --retry 3 -o "$TMP/xray.zip.dgst" "${URL}.dgst"; then
    want="$(grep 'SHA2-256' "$TMP/xray.zip.dgst" | awk '{print $NF}')"
    got="$(sha256sum "$TMP/xray.zip" | awk '{print $1}')"
    [ "$want" = "$got" ] || rdie "SHA-256 mismatch (want $want, got $got)"
    rinfo "SHA-256 verified: $got"
else
    rinfo "WARNING: no .dgst file, skipping checksum"
fi

rstep "4/9 Installing binary and geo data"
systemctl stop xray 2>/dev/null || true
unzip -qo "$TMP/xray.zip" -d "$TMP/x"
install -m 755 "$TMP/x/xray" /usr/local/bin/xray
install -d -m 755 /usr/local/share/xray /usr/local/etc/xray
install -m 644 "$TMP/x/geoip.dat" "$TMP/x/geosite.dat" /usr/local/share/xray/
rinfo "$(/usr/local/bin/xray version | head -1)"

rstep "5/9 Generating credentials"
STATE=/usr/local/etc/xray/client.env
UUID=""; PRIVATE_KEY=""; PUBLIC_KEY=""; SHORT_ID=""
if [ -f "$STATE" ]; then
    . "$STATE"
    rinfo "reusing existing credentials from $STATE (existing clients keep working)"
fi
[ -n "$UUID" ] || UUID="$(/usr/local/bin/xray uuid)"
if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    KEYS="$(/usr/local/bin/xray x25519)"
    # Older builds print "Private key:/Public key:", newer "PrivateKey:/Password:".
    PRIVATE_KEY="$(printf '%s\n' "$KEYS" | grep -i 'private' | head -1 | awk -F': *' '{print $NF}' | tr -d ' \r')"
    PUBLIC_KEY="$(printf '%s\n' "$KEYS" | grep -iE 'public|password' | head -1 | awk -F': *' '{print $NF}' | tr -d ' \r')"
fi
[ -n "$SHORT_ID" ] || SHORT_ID="$(openssl rand -hex 8)"
[ ${#PRIVATE_KEY} -ge 43 ] && [ ${#PUBLIC_KEY} -ge 43 ] || rdie "could not parse 'xray x25519' output"
umask 077
cat > "$STATE" <<EOF
UUID=$UUID
PRIVATE_KEY=$PRIVATE_KEY
PUBLIC_KEY=$PUBLIC_KEY
SHORT_ID=$SHORT_ID
EOF
umask 022
rinfo "UUID=$UUID  shortId=$SHORT_ID"

rstep "6/9 Writing /usr/local/etc/xray/config.json"
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-reality",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${SNI}:443",
          "xver": 0,
          "serverNames": [ "${SNI}" ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [ "${SHORT_ID}" ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ], "routeOnly": true }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "ip": [ "geoip:private" ], "outboundTag": "block" },
      { "type": "field", "protocol": [ "bittorrent" ], "outboundTag": "block" }
    ]
  }
}
EOF
chmod 644 /usr/local/etc/xray/config.json
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json >/dev/null ||
    { /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json; rdie "config test failed"; }
rinfo "config test OK"

rstep "7/9 systemd service, firewall, BBR"
cat > /etc/systemd/system/xray.service <<'EOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

if ss -ltnH "( sport = :${PORT} )" 2>/dev/null | grep -q .; then
    ss -ltnpH "( sport = :${PORT} )" || true
    rdie "port ${PORT} is already used by another program (see above); stop it or set XRAY_PORT"
fi

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "${PORT}/tcp" >/dev/null && rinfo "ufw: opened ${PORT}/tcp"
elif systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd -q --permanent --add-port="${PORT}/tcp" && firewall-cmd -q --reload &&
        rinfo "firewalld: opened ${PORT}/tcp"
else
    rinfo "no active ufw/firewalld; nothing to open"
fi

if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" != "bbr" ]; then
    modprobe tcp_bbr 2>/dev/null || true
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-xray-bbr.conf
    sysctl -q --system >/dev/null 2>&1 || true
fi
rinfo "TCP congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"

rstep "8/9 Starting Xray"
systemctl enable xray >/dev/null 2>&1
systemctl restart xray
sleep 2
if ! systemctl is-active --quiet xray; then
    journalctl -u xray -n 30 --no-pager || true
    rdie "xray failed to start (log above)"
fi
rinfo "xray.service is active, listening:"
ss -ltnH "( sport = :${PORT} )" | sed 's/^/             /'

rstep "9/9 Self-test: VLESS+REALITY client on the VPS -> server -> internet"
cat > "$TMP/client.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [ { "listen": "127.0.0.1", "port": 10899, "protocol": "socks" } ],
  "outbounds": [ {
    "protocol": "vless",
    "settings": { "vnext": [ { "address": "127.0.0.1", "port": ${PORT},
      "users": [ { "id": "${UUID}", "flow": "xtls-rprx-vision", "encryption": "none" } ] } ] },
    "streamSettings": { "network": "raw", "security": "reality",
      "realitySettings": { "serverName": "${SNI}", "fingerprint": "chrome",
        "publicKey": "${PUBLIC_KEY}", "shortId": "${SHORT_ID}" } }
  } ]
}
EOF
/usr/local/bin/xray run -config "$TMP/client.json" >"$TMP/client.log" 2>&1 &
CPID=$!
sleep 2
CODE="$(curl -s -m 15 -o /dev/null -w '%{http_code}' --socks5-hostname 127.0.0.1:10899 \
        https://www.gstatic.com/generate_204 || true)"
kill "$CPID" 2>/dev/null || true; wait "$CPID" 2>/dev/null || true
if [ "$CODE" = "204" ]; then
    rinfo "tunnel works (HTTP 204 from www.gstatic.com through the proxy)"
else
    tail -5 "$TMP/client.log" | sed 's/^/             /'
    journalctl -u xray -n 5 --no-pager | sed 's/^/             /'
    rdie "tunnel self-test failed (HTTP ${CODE:-none}); if REALITY handshakes fail, try another REALITY_SNI"
fi

echo "@@KV UUID=$UUID"
echo "@@KV PUBLIC_KEY=$PUBLIC_KEY"
echo "@@KV SHORT_ID=$SHORT_ID"
REMOTE

kv() { grep "^@@KV $1=" "$LOG" | tail -1 | cut -d= -f2- | tr -d '\r'; }
UUID="$(kv UUID)"; PUBLIC_KEY="$(kv PUBLIC_KEY)"; SHORT_ID="$(kv SHORT_ID)"
[ -n "$UUID" ] && [ -n "$PUBLIC_KEY" ] && [ -n "$SHORT_ID" ] ||
    die "remote install did not return credentials (see output above)"

# --------------------------------------------------------------------------
step "Checking that ${VPS_HOST}:${XRAY_PORT} is reachable from here"
if timeout 6 bash -c "exec 3<>/dev/tcp/${VPS_HOST}/${XRAY_PORT}" 2>/dev/null; then
    info "TCP ${XRAY_PORT} reachable"
else
    info "WARNING: cannot open TCP ${XRAY_PORT} from this machine."
    info "Check the VPS provider's firewall (e.g. Vultr Firewall group) allows ${XRAY_PORT}/tcp."
fi

# --------------------------------------------------------------------------
step "Writing Clash Verge profile to ${OUT_FILE}"
umask 077
cat > "$OUT_FILE" <<EOF
# Clash Verge (mihomo) profile generated $(date '+%F %T')
mixed-port: 7897
allow-lan: false
mode: rule
log-level: info
ipv6: false
unified-delay: true

dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - https://223.5.5.5/dns-query
    - https://doh.pub/dns-query

proxies:
  - name: ${PROXY_NAME}
    type: vless
    server: ${VPS_HOST}
    port: ${XRAY_PORT}
    uuid: ${UUID}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${REALITY_SNI}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - ${PROXY_NAME}
      - DIRECT

rules:
  - GEOIP,private,DIRECT,no-resolve
  - GEOSITE,cn,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
EOF
info "saved $(cd "$(dirname "$OUT_FILE")" && pwd)/$(basename "$OUT_FILE")"

VLESS_LINK="vless://${UUID}@${VPS_HOST}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${PROXY_NAME}"

printf '\n\033[1;32m========== Clash Verge profile (%s) ==========\033[0m\n' "$OUT_FILE"
cat "$OUT_FILE"
printf '\033[1;32m===============================================================\033[0m\n'
cat <<EOF

Import into Clash Verge:
  Profiles -> New -> Type "Local" -> select ${OUT_FILE} -> Save,
  then click the profile to activate it and turn on System Proxy.

Share link (for v2rayN / Shadowrocket / NekoBox):
  ${VLESS_LINK}

Done.
EOF
