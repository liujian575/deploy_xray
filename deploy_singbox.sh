#!/usr/bin/env bash
# Deploy sing-box with several proxy protocols to a remote VPS over SSH,
# self-test every protocol on the VPS, then write a Clash Verge (mihomo)
# profile with one node per protocol plus an auto-select group.
#
# Usage (run on your local machine):
#   ./deploy_singbox.sh         # asks for the VPS IP and root password
#
# Protocols (PROTOCOLS=comma list; default = all except plain "ss"):
#   vless-reality  tcp      VLESS + REALITY + XTLS-Vision            VLESS_PORT=443
#   anytls         tcp      AnyTLS (self-signed cert)                ANYTLS_PORT=8443
#   trojan         tcp      Trojan (self-signed cert)                TROJAN_PORT=2087
#   shadowtls      tcp      ShadowTLS v3 wrapping Shadowsocks-2022   SHADOWTLS_PORT=9443
#   hysteria2      udp      Hysteria2 + UDP port hopping             HY2_PORT=443  HY2_HOP=20000-50000
#   tuic           udp      TUIC v5                                  TUIC_PORT=8443
#   ss             tcp+udp  plain Shadowsocks-2022 (opt-in: the GFW  SS_PORT=8388
#                           detects fully-encrypted traffic easily)
#   PROTOCOLS=all enables every protocol, including ss.
#
# The GFW sometimes blocks *all TCP* to a VPS IP while UDP still passes; the
# UDP protocols (hysteria2, tuic) keep working then. Mixing TCP and UDP
# protocols on one VPS is the point of this script.
#
# Optional overrides via environment (skip the prompts / change defaults):
#   VPS_HOST=<ip or hostname>   SSHPASS=<password> (empty = SSH key auth)
#   VPS_USER=root  VPS_SSH_PORT=22
#   SING_BOX_VERSION=1.14.4
#   REALITY_SNI=www.apple.com   # real TLS 1.3 site used by REALITY and ShadowTLS
#   CERT_SNI=www.bing.com       # name in the self-signed cert (anytls/trojan/hy2/tuic)
#   HY2_HOP=                    # empty disables Hysteria2 port hopping
#   OUT_FILE=./clash-singbox-<host>.yaml
#
# Re-running is safe: credentials are kept in /etc/sing-box/client.env on the
# VPS, so existing clients keep working. If the VPS was set up with
# deploy_xray.sh, its VLESS UUID / REALITY keys are reused and xray is stopped.

set -euo pipefail

VPS_HOST="${VPS_HOST:-}"
VPS_USER="${VPS_USER:-root}"
VPS_SSH_PORT="${VPS_SSH_PORT:-22}"
SING_BOX_VERSION="${SING_BOX_VERSION:-1.14.4}"
PROTOCOLS="${PROTOCOLS:-vless-reality,anytls,trojan,shadowtls,hysteria2,tuic}"
REALITY_SNI="${REALITY_SNI:-www.apple.com}"
CERT_SNI="${CERT_SNI:-www.bing.com}"
VLESS_PORT="${VLESS_PORT:-443}"
ANYTLS_PORT="${ANYTLS_PORT:-8443}"
TROJAN_PORT="${TROJAN_PORT:-2087}"
SHADOWTLS_PORT="${SHADOWTLS_PORT:-9443}"
SS_PORT="${SS_PORT:-8388}"
HY2_PORT="${HY2_PORT:-443}"
HY2_HOP="${HY2_HOP-20000-50000}"
TUIC_PORT="${TUIC_PORT:-8443}"

ALL_PROTOCOLS="vless-reality anytls trojan shadowtls hysteria2 tuic ss"

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

PROTOCOLS="$(printf '%s' "$PROTOCOLS" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
[ "$PROTOCOLS" = all ] && PROTOCOLS="$(echo $ALL_PROTOCOLS | tr ' ' ',')"
for p in ${PROTOCOLS//,/ }; do
    case " $ALL_PROTOCOLS " in *" $p "*) ;; *) die "unknown protocol '$p' (valid: $ALL_PROTOCOLS, all)" ;; esac
done
[ -n "$PROTOCOLS" ] || die "PROTOCOLS is empty"
has() { case ",$PROTOCOLS," in *",$1,"*) return 0 ;; esac; return 1; }

for v in VLESS_PORT ANYTLS_PORT TROJAN_PORT SHADOWTLS_PORT SS_PORT HY2_PORT TUIC_PORT VPS_SSH_PORT; do
    [[ "${!v}" =~ ^[0-9]+$ ]] && [ "${!v}" -ge 1 ] && [ "${!v}" -le 65535 ] || die "$v='${!v}' is not a port"
done
for v in REALITY_SNI CERT_SNI; do
    [[ "${!v}" =~ ^[A-Za-z0-9.-]+$ ]] || die "$v='${!v}' is not a hostname"
done
[[ "$SING_BOX_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || die "bad SING_BOX_VERSION"
HOP_LO=""; HOP_HI=""
if has hysteria2 && [ -n "$HY2_HOP" ]; then
    [[ "$HY2_HOP" =~ ^([0-9]+)-([0-9]+)$ ]] || die "HY2_HOP='$HY2_HOP' must look like 20000-50000"
    HOP_LO="${BASH_REMATCH[1]}"; HOP_HI="${BASH_REMATCH[2]}"
    [ "$HOP_LO" -lt "$HOP_HI" ] && [ "$HOP_HI" -le 65535 ] || die "bad HY2_HOP range"
fi

# Each enabled protocol needs its own port per transport (tcp/udp).
declare -A USED=()
claim() { # proto transport port
    local key="$2/$3"
    [ -z "${USED[$key]:-}" ] || die "port $key is used by both ${USED[$key]} and $1"
    USED[$key]="$1"
    if [ "$2" = udp ] && [ -n "$HOP_LO" ] && [ "$1" != hysteria2 ] &&
       [ "$3" -ge "$HOP_LO" ] && [ "$3" -le "$HOP_HI" ]; then
        die "$1 udp port $3 is inside HY2_HOP $HY2_HOP (it would be redirected to Hysteria2)"
    fi
}
has vless-reality && claim vless-reality tcp "$VLESS_PORT"
has anytls        && claim anytls tcp "$ANYTLS_PORT"
has trojan        && claim trojan tcp "$TROJAN_PORT"
has shadowtls     && claim shadowtls tcp "$SHADOWTLS_PORT"
has ss            && claim ss tcp "$SS_PORT" && claim ss udp "$SS_PORT"
has hysteria2     && claim hysteria2 udp "$HY2_PORT"
has tuic          && claim tuic udp "$TUIC_PORT"

while [ -z "$VPS_HOST" ]; do
    read -r -p "    VPS IP address (or hostname): " VPS_HOST
    VPS_HOST="$(printf '%s' "$VPS_HOST" | tr -d '[:space:]')"
done
if [ -z "${SSHPASS+x}" ]; then
    read -r -s -p "    SSH password for ${VPS_USER}@${VPS_HOST} (empty = use SSH key): " SSHPASS
    echo
fi
OUT_FILE="${OUT_FILE:-./clash-singbox-${VPS_HOST}.yaml}"
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
info "target    : ${VPS_USER}@${VPS_HOST}:${VPS_SSH_PORT}"
info "sing-box  : v${SING_BOX_VERSION}"
info "protocols : ${PROTOCOLS//,/, }"

# --------------------------------------------------------------------------
step "Testing SSH connection"
"${SSH_CMD[@]}" "${VPS_USER}@${VPS_HOST}" 'echo "    connected: $(hostname) / $(uname -sr)"' ||
    die "cannot SSH to ${VPS_USER}@${VPS_HOST}: check the IP and password.
       If the VPS was reinstalled, clear its old host key first: ssh-keygen -R ${VPS_HOST}"

# --------------------------------------------------------------------------
step "Installing and configuring sing-box on the VPS"
REMOTE_ENV="SB_VER=$SING_BOX_VERSION PROTOCOLS=$PROTOCOLS REALITY_SNI=$REALITY_SNI CERT_SNI=$CERT_SNI"
REMOTE_ENV+=" VLESS_PORT=$VLESS_PORT ANYTLS_PORT=$ANYTLS_PORT TROJAN_PORT=$TROJAN_PORT"
REMOTE_ENV+=" SHADOWTLS_PORT=$SHADOWTLS_PORT SS_PORT=$SS_PORT HY2_PORT=$HY2_PORT TUIC_PORT=$TUIC_PORT"
REMOTE_ENV+=" HOP_LO=$HOP_LO HOP_HI=$HOP_HI"
"${SSH_CMD[@]}" "${VPS_USER}@${VPS_HOST}" "env $REMOTE_ENV bash -s" \
    <<'REMOTE' 2>&1 | tee "$LOG" | grep -v '^@@KV '
set -euo pipefail
rstep() { printf '\033[1;36m    [remote] %s\033[0m\n' "$*"; }
rinfo() { printf '             %s\n' "$*"; }
rwarn() { printf '\033[1;33m             WARNING: %s\033[0m\n' "$*"; }
rdie()  { printf '\033[1;31m    [remote] ERROR: %s\033[0m\n' "$*"; exit 1; }
has() { case ",$PROTOCOLS," in *",$1,"*) return 0 ;; esac; return 1; }
need_cert() { has anytls || has trojan || has hysteria2 || has tuic; }

SB=/usr/local/bin/sing-box
ETC=/etc/sing-box
STLS_INNER_PORT=59388   # 127.0.0.1-only Shadowsocks behind ShadowTLS

[ "$(id -u)" = 0 ] || rdie "must run as root"
command -v systemctl >/dev/null || rdie "systemd is required"

rstep "1/9 Detecting system"
OS_NAME="$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown OS}")"
case "$(uname -m)" in
    x86_64|amd64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) rdie "unsupported architecture $(uname -m)" ;;
esac
rinfo "${OS_NAME}, $(uname -m), kernel $(uname -r)"

rstep "2/9 Installing dependencies (curl tar openssl nftables)"
PKGS="curl tar openssl ca-certificates"
[ -n "$HOP_LO" ] && PKGS="$PKGS nftables"
if command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null
    apt-get install -y -qq $PKGS iproute2 >/dev/null
elif command -v dnf >/dev/null; then
    dnf install -y -q $PKGS iproute >/dev/null
elif command -v yum >/dev/null; then
    yum install -y -q $PKGS iproute >/dev/null
else
    rdie "no supported package manager (apt/dnf/yum)"
fi

rstep "3/9 Downloading sing-box v${SB_VER}"
TMP="$(mktemp -d)"
CPID=""
cleanup() { [ -n "$CPID" ] && kill "$CPID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
NAME="sing-box-${SB_VER}-linux-${ARCH}"
URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/${NAME}.tar.gz"
rinfo "$URL"
curl -fsSL --retry 3 -o "$TMP/sb.tgz" "$URL" || rdie "download failed"
tar -xzf "$TMP/sb.tgz" -C "$TMP"
"$TMP/$NAME/sing-box" version | head -1 | grep -q "version ${SB_VER}\$" ||
    rdie "downloaded binary does not report version ${SB_VER}"
install -m 755 "$TMP/$NAME/sing-box" "$SB"
rinfo "$($SB version | head -1)  (sha256 $(sha256sum "$SB" | cut -c1-16)...)"

rstep "4/9 Credentials"
install -d -m 755 "$ETC"
STATE="$ETC/client.env"
VLESS_UUID=""; REALITY_PRIVATE_KEY=""; REALITY_PUBLIC_KEY=""; REALITY_SHORT_ID=""
ANYTLS_PASSWORD=""; TROJAN_PASSWORD=""; SHADOWTLS_PASSWORD=""; SS_PASSWORD=""
HY2_PASSWORD=""; TUIC_UUID=""; TUIC_PASSWORD=""
if [ -f "$STATE" ]; then
    . "$STATE"
    rinfo "reusing credentials from $STATE (existing clients keep working)"
fi
XRAY_STATE=/usr/local/etc/xray/client.env
if [ -z "$VLESS_UUID" ] && [ -f "$XRAY_STATE" ]; then
    UUID=""; PRIVATE_KEY=""; PUBLIC_KEY=""; SHORT_ID=""
    . "$XRAY_STATE"
    VLESS_UUID="$UUID"; REALITY_PRIVATE_KEY="$PRIVATE_KEY"
    REALITY_PUBLIC_KEY="$PUBLIC_KEY"; REALITY_SHORT_ID="$SHORT_ID"
    rinfo "imported VLESS UUID and REALITY keys from $XRAY_STATE (deploy_xray.sh)"
fi
rhex() { openssl rand -hex 16; }
[ -n "$VLESS_UUID" ] || VLESS_UUID="$($SB generate uuid)"
if [ -z "$REALITY_PRIVATE_KEY" ] || [ -z "$REALITY_PUBLIC_KEY" ]; then
    KEYS="$($SB generate reality-keypair)"
    REALITY_PRIVATE_KEY="$(printf '%s\n' "$KEYS" | awk '/PrivateKey/ {print $2}')"
    REALITY_PUBLIC_KEY="$(printf '%s\n' "$KEYS" | awk '/PublicKey/ {print $2}')"
fi
[ ${#REALITY_PRIVATE_KEY} -ge 43 ] && [ ${#REALITY_PUBLIC_KEY} -ge 43 ] ||
    rdie "could not parse 'sing-box generate reality-keypair' output"
[ -n "$REALITY_SHORT_ID" ]   || REALITY_SHORT_ID="$(openssl rand -hex 8)"
[ -n "$ANYTLS_PASSWORD" ]    || ANYTLS_PASSWORD="$(rhex)"
[ -n "$TROJAN_PASSWORD" ]    || TROJAN_PASSWORD="$(rhex)"
[ -n "$SHADOWTLS_PASSWORD" ] || SHADOWTLS_PASSWORD="$(rhex)"
[ -n "$SS_PASSWORD" ]        || SS_PASSWORD="$($SB generate rand --base64 16)"
[ -n "$HY2_PASSWORD" ]       || HY2_PASSWORD="$(rhex)"
[ -n "$TUIC_UUID" ]          || TUIC_UUID="$($SB generate uuid)"
[ -n "$TUIC_PASSWORD" ]      || TUIC_PASSWORD="$(rhex)"
umask 077
cat > "$STATE" <<EOF
VLESS_UUID=$VLESS_UUID
REALITY_PRIVATE_KEY=$REALITY_PRIVATE_KEY
REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY
REALITY_SHORT_ID=$REALITY_SHORT_ID
ANYTLS_PASSWORD=$ANYTLS_PASSWORD
TROJAN_PASSWORD=$TROJAN_PASSWORD
SHADOWTLS_PASSWORD=$SHADOWTLS_PASSWORD
SS_PASSWORD=$SS_PASSWORD
HY2_PASSWORD=$HY2_PASSWORD
TUIC_UUID=$TUIC_UUID
TUIC_PASSWORD=$TUIC_PASSWORD
EOF
umask 022
rinfo "saved to $STATE"

rstep "5/9 TLS: self-signed certificate and REALITY target check"
if need_cert; then
    if [ -f "$ETC/cert.pem" ] && [ -f "$ETC/key.pem" ] &&
       openssl x509 -in "$ETC/cert.pem" -noout -subject 2>/dev/null | grep -q "CN *= *${CERT_SNI}\$"; then
        rinfo "reusing $ETC/cert.pem (CN=${CERT_SNI})"
    else
        openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
            -subj "/CN=${CERT_SNI}" -addext "subjectAltName=DNS:${CERT_SNI}" \
            -keyout "$ETC/key.pem" -out "$ETC/cert.pem" 2>/dev/null
        rinfo "generated self-signed cert for ${CERT_SNI} (clients use skip-cert-verify)"
    fi
fi
if has vless-reality || has shadowtls; then
    OUT="$(timeout 10 openssl s_client -connect "${REALITY_SNI}:443" -servername "$REALITY_SNI" \
           -tls1_3 -alpn h2 </dev/null 2>&1 || true)"
    if printf '%s' "$OUT" | grep -q 'TLSv1.3' && printf '%s' "$OUT" | grep -q 'ALPN protocol: h2'; then
        rinfo "${REALITY_SNI}:443 speaks TLS 1.3 + h2 (good REALITY/ShadowTLS target)"
    else
        rwarn "${REALITY_SNI}:443 did not negotiate TLS 1.3 + h2 from this VPS; pick another REALITY_SNI"
    fi
fi

rstep "6/9 Writing $ETC/config.json"
TLS_CERT="\"certificate_path\": \"$ETC/cert.pem\", \"key_path\": \"$ETC/key.pem\""
IN=()
has vless-reality && IN+=("{
      \"type\": \"vless\", \"tag\": \"vless-reality\", \"listen\": \"::\", \"listen_port\": ${VLESS_PORT},
      \"users\": [ { \"name\": \"user\", \"uuid\": \"${VLESS_UUID}\", \"flow\": \"xtls-rprx-vision\" } ],
      \"tls\": { \"enabled\": true, \"server_name\": \"${REALITY_SNI}\",
        \"reality\": { \"enabled\": true,
          \"handshake\": { \"server\": \"${REALITY_SNI}\", \"server_port\": 443 },
          \"private_key\": \"${REALITY_PRIVATE_KEY}\", \"short_id\": [ \"${REALITY_SHORT_ID}\" ] } } }")
has anytls && IN+=("{
      \"type\": \"anytls\", \"tag\": \"anytls\", \"listen\": \"::\", \"listen_port\": ${ANYTLS_PORT},
      \"users\": [ { \"name\": \"user\", \"password\": \"${ANYTLS_PASSWORD}\" } ],
      \"tls\": { \"enabled\": true, ${TLS_CERT} } }")
has trojan && IN+=("{
      \"type\": \"trojan\", \"tag\": \"trojan\", \"listen\": \"::\", \"listen_port\": ${TROJAN_PORT},
      \"users\": [ { \"name\": \"user\", \"password\": \"${TROJAN_PASSWORD}\" } ],
      \"tls\": { \"enabled\": true, ${TLS_CERT} } }")
has shadowtls && IN+=("{
      \"type\": \"shadowtls\", \"tag\": \"shadowtls\", \"listen\": \"::\", \"listen_port\": ${SHADOWTLS_PORT},
      \"version\": 3, \"strict_mode\": true,
      \"users\": [ { \"name\": \"user\", \"password\": \"${SHADOWTLS_PASSWORD}\" } ],
      \"handshake\": { \"server\": \"${REALITY_SNI}\", \"server_port\": 443 },
      \"detour\": \"ss-shadowtls\" }" "{
      \"type\": \"shadowsocks\", \"tag\": \"ss-shadowtls\", \"listen\": \"127.0.0.1\",
      \"listen_port\": ${STLS_INNER_PORT}, \"network\": \"tcp\",
      \"method\": \"2022-blake3-aes-128-gcm\", \"password\": \"${SS_PASSWORD}\" }")
has ss && IN+=("{
      \"type\": \"shadowsocks\", \"tag\": \"ss\", \"listen\": \"::\", \"listen_port\": ${SS_PORT},
      \"method\": \"2022-blake3-aes-128-gcm\", \"password\": \"${SS_PASSWORD}\" }")
has hysteria2 && IN+=("{
      \"type\": \"hysteria2\", \"tag\": \"hysteria2\", \"listen\": \"::\", \"listen_port\": ${HY2_PORT},
      \"users\": [ { \"name\": \"user\", \"password\": \"${HY2_PASSWORD}\" } ],
      \"masquerade\": { \"type\": \"proxy\", \"url\": \"https://${CERT_SNI}/\", \"rewrite_host\": true },
      \"tls\": { \"enabled\": true, \"alpn\": [ \"h3\" ], ${TLS_CERT} } }")
has tuic && IN+=("{
      \"type\": \"tuic\", \"tag\": \"tuic\", \"listen\": \"::\", \"listen_port\": ${TUIC_PORT},
      \"users\": [ { \"name\": \"user\", \"uuid\": \"${TUIC_UUID}\", \"password\": \"${TUIC_PASSWORD}\" } ],
      \"congestion_control\": \"bbr\",
      \"tls\": { \"enabled\": true, \"alpn\": [ \"h3\" ], ${TLS_CERT} } }")
join() { local IFS=$'\n'; local out="" x; for x in "$@"; do out+="${out:+,
    }$x"; done; printf '%s' "$out"; }
cat > "$TMP/config.json" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    $(join "${IN[@]}")
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "route": {
    "rules": [
      { "action": "sniff" },
      { "ip_is_private": true, "action": "reject" },
      { "protocol": "bittorrent", "action": "reject" }
    ]
  }
}
EOF
$SB check -c "$TMP/config.json" || rdie "sing-box rejected the generated config"
id sing-box >/dev/null 2>&1 ||
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin sing-box
install -m 640 -g sing-box "$TMP/config.json" "$ETC/config.json"
need_cert && chgrp sing-box "$ETC/cert.pem" "$ETC/key.pem" && chmod 640 "$ETC/cert.pem" "$ETC/key.pem"
rinfo "config check OK ($(printf '%s\n' "${IN[@]}" | grep -c '"type"') inbounds)"

rstep "7/9 Ports, firewall, port hopping, BBR"
# Old services (deploy_xray.sh's xray, a standalone hysteria) holding our ports are retired.
PORTS=()
has vless-reality && PORTS+=("tcp $VLESS_PORT")
has anytls        && PORTS+=("tcp $ANYTLS_PORT")
has trojan        && PORTS+=("tcp $TROJAN_PORT")
has shadowtls     && PORTS+=("tcp $SHADOWTLS_PORT" "tcp $STLS_INNER_PORT")
has ss            && PORTS+=("tcp $SS_PORT" "udp $SS_PORT")
has hysteria2     && PORTS+=("udp $HY2_PORT")
has tuic          && PORTS+=("udp $TUIC_PORT")
for e in "${PORTS[@]}"; do
    set -- $e
    flag=-lntp; [ "$1" = udp ] && flag=-lnup
    pid="$(ss -H $flag "( sport = :$2 )" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1 || true)"
    [ -n "$pid" ] || continue
    comm="$(cat /proc/$pid/comm 2>/dev/null || true)"
    unit="$(ps -o unit= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    case "$comm" in
        sing-box) ;;
        xray|hysteria)
            rinfo "$1/$2 is held by $comm ($unit): stopping and disabling it"
            if [ -n "$unit" ] && [ "${unit%.service}" != "$unit" ]; then
                systemctl disable --now "$unit" >/dev/null 2>&1 || true
            else
                kill "$pid" || true
            fi
            sleep 1 ;;
        *) ss -H $flag "( sport = :$2 )" || true
           rdie "$1 port $2 is used by '$comm' (pid $pid); free it or change the port" ;;
    esac
done

open_port() { # proto port-or-range(a:b)
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
        ufw allow "$2/$1" >/dev/null && rinfo "ufw: opened $2/$1"
    elif systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd -q --permanent --add-port="${2/:/-}/$1" && rinfo "firewalld: opened ${2/:/-}/$1"
    fi
}
for e in "${PORTS[@]}"; do set -- $e; [ "$2" = "$STLS_INNER_PORT" ] || open_port "$1" "$2"; done
[ -n "$HOP_LO" ] && open_port udp "${HOP_LO}:${HOP_HI}"
systemctl is-active --quiet firewalld 2>/dev/null && firewall-cmd -q --reload || true
if ! { command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; } &&
   ! systemctl is-active --quiet firewalld 2>/dev/null; then
    rinfo "no active ufw/firewalld; nothing to open"
fi

if [ -n "$HOP_LO" ]; then
    cat > "$ETC/porthop.nft" <<EOF
table inet sing_box_porthop
delete table inet sing_box_porthop
table inet sing_box_porthop {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    udp dport ${HOP_LO}-${HOP_HI} redirect to :${HY2_PORT}
  }
}
EOF
    cat > /etc/systemd/system/sing-box-porthop.service <<EOF
[Unit]
Description=Hysteria2 UDP port hopping (${HOP_LO}-${HOP_HI} -> ${HY2_PORT})
After=network-online.target
Before=sing-box.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$(command -v nft) -f $ETC/porthop.nft
ExecStop=$(command -v nft) delete table inet sing_box_porthop

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box-porthop >/dev/null 2>&1
    systemctl restart sing-box-porthop
    rinfo "port hopping: udp ${HOP_LO}-${HOP_HI} -> ${HY2_PORT} (sing-box-porthop.service)"
elif systemctl list-unit-files sing-box-porthop.service >/dev/null 2>&1; then
    systemctl disable --now sing-box-porthop >/dev/null 2>&1 || true
fi

if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" != "bbr" ]; then
    modprobe tcp_bbr 2>/dev/null || true
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-sing-box-bbr.conf
fi
printf 'net.core.rmem_max=16777216\nnet.core.wmem_max=16777216\n' > /etc/sysctl.d/99-sing-box-udp.conf
sysctl -q --system >/dev/null 2>&1 || true
rinfo "TCP congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null); UDP buffers 16 MiB"

rstep "8/9 Starting sing-box"
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target
Wants=network-online.target

[Service]
User=sing-box
Group=sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStartPre=$SB check -c $ETC/config.json
ExecStart=$SB run -c $ETC/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1
systemctl restart sing-box
sleep 2
if ! systemctl is-active --quiet sing-box; then
    journalctl -u sing-box -n 30 --no-pager || true
    rdie "sing-box failed to start (log above)"
fi
rinfo "sing-box.service is active, listening:"
ss -H -lntup 2>/dev/null | grep '"sing-box"' | awk '{printf "             %-4s %s\n", $1, $5}'

rstep "9/9 Self-test: a sing-box client on the VPS -> each protocol -> internet"
TLS_INSECURE="\"enabled\": true, \"server_name\": \"${CERT_SNI}\", \"insecure\": true"
OUT=(); RULES=(); MIXED=(); NAMES=()
port=10900
addtest() { # name outbound-json
    port=$((port + 1)); NAMES+=("$1:$port")
    MIXED+=("{ \"type\": \"mixed\", \"tag\": \"in-$1\", \"listen\": \"127.0.0.1\", \"listen_port\": $port }")
    RULES+=("{ \"inbound\": [ \"in-$1\" ], \"action\": \"route\", \"outbound\": \"$1\" }")
    OUT+=("$2")
}
has vless-reality && addtest vless-reality "{ \"type\": \"vless\", \"tag\": \"vless-reality\",
    \"server\": \"127.0.0.1\", \"server_port\": ${VLESS_PORT}, \"uuid\": \"${VLESS_UUID}\", \"flow\": \"xtls-rprx-vision\",
    \"tls\": { \"enabled\": true, \"server_name\": \"${REALITY_SNI}\", \"utls\": { \"enabled\": true, \"fingerprint\": \"chrome\" },
      \"reality\": { \"enabled\": true, \"public_key\": \"${REALITY_PUBLIC_KEY}\", \"short_id\": \"${REALITY_SHORT_ID}\" } } }"
has anytls && addtest anytls "{ \"type\": \"anytls\", \"tag\": \"anytls\", \"server\": \"127.0.0.1\",
    \"server_port\": ${ANYTLS_PORT}, \"password\": \"${ANYTLS_PASSWORD}\", \"tls\": { ${TLS_INSECURE} } }"
has trojan && addtest trojan "{ \"type\": \"trojan\", \"tag\": \"trojan\", \"server\": \"127.0.0.1\",
    \"server_port\": ${TROJAN_PORT}, \"password\": \"${TROJAN_PASSWORD}\", \"tls\": { ${TLS_INSECURE} } }"
if has shadowtls; then
    addtest shadowtls "{ \"type\": \"shadowsocks\", \"tag\": \"shadowtls\", \"method\": \"2022-blake3-aes-128-gcm\",
    \"password\": \"${SS_PASSWORD}\", \"detour\": \"shadowtls-transport\" }"
    OUT+=("{ \"type\": \"shadowtls\", \"tag\": \"shadowtls-transport\", \"server\": \"127.0.0.1\",
    \"server_port\": ${SHADOWTLS_PORT}, \"version\": 3, \"password\": \"${SHADOWTLS_PASSWORD}\",
    \"tls\": { \"enabled\": true, \"server_name\": \"${REALITY_SNI}\", \"utls\": { \"enabled\": true, \"fingerprint\": \"chrome\" } } }")
fi
has ss && addtest ss "{ \"type\": \"shadowsocks\", \"tag\": \"ss\", \"server\": \"127.0.0.1\",
    \"server_port\": ${SS_PORT}, \"method\": \"2022-blake3-aes-128-gcm\", \"password\": \"${SS_PASSWORD}\" }"
has hysteria2 && addtest hysteria2 "{ \"type\": \"hysteria2\", \"tag\": \"hysteria2\", \"server\": \"127.0.0.1\",
    \"server_port\": ${HY2_PORT}, \"password\": \"${HY2_PASSWORD}\",
    \"tls\": { ${TLS_INSECURE}, \"alpn\": [ \"h3\" ] } }"
has tuic && addtest tuic "{ \"type\": \"tuic\", \"tag\": \"tuic\", \"server\": \"127.0.0.1\",
    \"server_port\": ${TUIC_PORT}, \"uuid\": \"${TUIC_UUID}\", \"password\": \"${TUIC_PASSWORD}\",
    \"congestion_control\": \"bbr\", \"tls\": { ${TLS_INSECURE}, \"alpn\": [ \"h3\" ] } }"
cat > "$TMP/client.json" <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [ $(join "${MIXED[@]}") ],
  "outbounds": [ $(join "${OUT[@]}") ],
  "route": { "rules": [ $(join "${RULES[@]}") ] }
}
EOF
$SB check -c "$TMP/client.json" || rdie "self-test client config invalid"
$SB run -c "$TMP/client.json" >"$TMP/client.log" 2>&1 &
CPID=$!
sleep 2
FAILED=""
for e in "${NAMES[@]}"; do
    name="${e%%:*}"; p="${e##*:}"
    code="$(curl -s -m 15 -o /dev/null -w '%{http_code}' -x "socks5h://127.0.0.1:$p" \
            https://www.gstatic.com/generate_204 || true)"
    if [ "$code" = 204 ]; then
        printf '             \033[32mPASS\033[0m  %s\n' "$name"
    else
        printf '             \033[31mFAIL\033[0m  %s (HTTP %s)\n' "$name" "${code:-none}"
        FAILED="$FAILED $name"
    fi
done
kill "$CPID" 2>/dev/null || true; wait "$CPID" 2>/dev/null || true; CPID=""
if [ -n "$FAILED" ]; then
    tail -10 "$TMP/client.log" | sed 's/^/             client: /'
    journalctl -u sing-box -n 10 --no-pager | sed 's/^/             server: /'
    rdie "self-test failed for:$FAILED"
fi

for v in VLESS_UUID REALITY_PUBLIC_KEY REALITY_SHORT_ID ANYTLS_PASSWORD TROJAN_PASSWORD \
         SHADOWTLS_PASSWORD SS_PASSWORD HY2_PASSWORD TUIC_UUID TUIC_PASSWORD; do
    echo "@@KV $v=${!v}"
done
REMOTE

kv() { grep "^@@KV $1=" "$LOG" | tail -1 | cut -d= -f2- | tr -d '\r'; }
for v in VLESS_UUID REALITY_PUBLIC_KEY REALITY_SHORT_ID ANYTLS_PASSWORD TROJAN_PASSWORD \
         SHADOWTLS_PASSWORD SS_PASSWORD HY2_PASSWORD TUIC_UUID TUIC_PASSWORD; do
    printf -v "$v" '%s' "$(kv "$v")"
    [ -n "${!v}" ] || die "remote install did not return credentials (see output above)"
done

# --------------------------------------------------------------------------
step "Checking which TCP ports are reachable from here"
for e in vless-reality:$VLESS_PORT anytls:$ANYTLS_PORT trojan:$TROJAN_PORT \
         shadowtls:$SHADOWTLS_PORT ss:$SS_PORT; do
    has "${e%%:*}" || continue
    if timeout 6 bash -c "exec 3<>/dev/tcp/${VPS_HOST}/${e##*:}" 2>/dev/null; then
        info "tcp ${e##*:} (${e%%:*}) reachable"
    else
        info "WARNING: tcp ${e##*:} (${e%%:*}) NOT reachable from here (provider firewall? GFW TCP block?)"
    fi
done
info "UDP (hysteria2/tuic) cannot be probed this way; it was verified by the self-test on the VPS."
info "Note: if this machine itself goes through a proxy/TUN, these results say little about the GFW."

# --------------------------------------------------------------------------
step "Writing Clash Verge profile to ${OUT_FILE}"
H="$VPS_HOST"
NODES=()
PROXIES=""
add() { NODES+=("$1"); PROXIES+="$2"$'\n'; }
has hysteria2 && add "hy2-$H" "  - name: hy2-$H
    type: hysteria2
    server: $H
    port: $HY2_PORT$( [ -n "$HOP_LO" ] && printf '\n    ports: %s-%s\n    hop-interval: 30' "$HOP_LO" "$HOP_HI")
    password: $HY2_PASSWORD
    sni: $CERT_SNI
    skip-cert-verify: true
    alpn: [h3]
"
has tuic && add "tuic-$H" "  - name: tuic-$H
    type: tuic
    server: $H
    port: $TUIC_PORT
    uuid: $TUIC_UUID
    password: $TUIC_PASSWORD
    congestion-control: bbr
    udp-relay-mode: native
    reduce-rtt: false
    sni: $CERT_SNI
    alpn: [h3]
    skip-cert-verify: true
"
has vless-reality && add "vless-reality-$H" "  - name: vless-reality-$H
    type: vless
    server: $H
    port: $VLESS_PORT
    uuid: $VLESS_UUID
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: $REALITY_SNI
    client-fingerprint: chrome
    reality-opts:
      public-key: $REALITY_PUBLIC_KEY
      short-id: $REALITY_SHORT_ID
"
has anytls && add "anytls-$H" "  - name: anytls-$H
    type: anytls
    server: $H
    port: $ANYTLS_PORT
    password: $ANYTLS_PASSWORD
    client-fingerprint: chrome
    udp: true
    sni: $CERT_SNI
    skip-cert-verify: true
"
has shadowtls && add "shadowtls-$H" "  - name: shadowtls-$H
    type: ss
    server: $H
    port: $SHADOWTLS_PORT
    cipher: 2022-blake3-aes-128-gcm
    password: \"$SS_PASSWORD\"
    udp-over-tcp: true
    udp-over-tcp-version: 2
    plugin: shadow-tls
    client-fingerprint: chrome
    plugin-opts:
      host: $REALITY_SNI
      password: \"$SHADOWTLS_PASSWORD\"
      version: 3
"
has trojan && add "trojan-$H" "  - name: trojan-$H
    type: trojan
    server: $H
    port: $TROJAN_PORT
    password: $TROJAN_PASSWORD
    udp: true
    sni: $CERT_SNI
    skip-cert-verify: true
    client-fingerprint: chrome
"
has ss && add "ss-$H" "  - name: ss-$H
    type: ss
    server: $H
    port: $SS_PORT
    cipher: 2022-blake3-aes-128-gcm
    password: \"$SS_PASSWORD\"
    udp: true
"
node_list() { local n; for n in "${NODES[@]}"; do printf '      - %s\n' "$n"; done; }

umask 077
cat > "$OUT_FILE" <<EOF
# Clash Verge (mihomo) profile generated $(date '+%F %T') by deploy_singbox.sh
# sing-box v${SING_BOX_VERSION} on ${H}: ${PROTOCOLS//,/, }
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
${PROXIES}
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - AUTO
$(node_list)
      - DIRECT
  # Picks the fastest node that currently works; skips protocols the GFW blocks.
  - name: AUTO
    type: url-test
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    proxies:
$(node_list)

rules:
  - GEOIP,private,DIRECT,no-resolve
  - GEOSITE,cn,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
EOF
info "saved $(cd "$(dirname "$OUT_FILE")" && pwd)/$(basename "$OUT_FILE")"

# --------------------------------------------------------------------------
urlenc() { local s="$1" o="" c i; for ((i = 0; i < ${#s}; i++)); do c="${s:i:1}"
    case "$c" in [A-Za-z0-9._~-]) o+="$c" ;; *) o+="$(printf '%%%02X' "'$c")" ;; esac; done; printf '%s' "$o"; }
LINKS=()
has hysteria2 && LINKS+=("hysteria2://${HY2_PASSWORD}@${H}:${HY2_PORT}?sni=${CERT_SNI}&insecure=1&alpn=h3$( [ -n "$HOP_LO" ] && printf '&mport=%s-%s' "$HOP_LO" "$HOP_HI")#hy2-${H}")
has tuic && LINKS+=("tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${H}:${TUIC_PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${CERT_SNI}&allow_insecure=1#tuic-${H}")
has vless-reality && LINKS+=("vless://${VLESS_UUID}@${H}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp#vless-reality-${H}")
has anytls && LINKS+=("anytls://${ANYTLS_PASSWORD}@${H}:${ANYTLS_PORT}?sni=${CERT_SNI}&insecure=1#anytls-${H}")
has trojan && LINKS+=("trojan://${TROJAN_PASSWORD}@${H}:${TROJAN_PORT}?security=tls&sni=${CERT_SNI}&allowInsecure=1&type=tcp#trojan-${H}")
has ss && LINKS+=("ss://2022-blake3-aes-128-gcm:$(urlenc "$SS_PASSWORD")@${H}:${SS_PORT}#ss-${H}")

printf '\n\033[1;32m========== Clash Verge profile (%s) ==========\033[0m\n' "$OUT_FILE"
cat "$OUT_FILE"
printf '\033[1;32m===============================================================\033[0m\n'
cat <<EOF

Import into Clash Verge:
  Profiles -> New -> Type "Local" -> select ${OUT_FILE} -> Save,
  then click the profile to activate it and turn on System Proxy.
  Keep the mode on "Rule" so Chinese sites go DIRECT, not through the VPS.

Share links (v2rayN / NekoBox / Shadowrocket / sing-box clients):
EOF
for l in "${LINKS[@]}"; do printf '  %s\n' "$l"; done
has shadowtls && echo "  (ShadowTLS has no standard share link; use the Clash profile.)"
echo
echo "If the VPS provider has its own firewall (e.g. Vultr Firewall group, AWS security group),"
echo "allow the ports above there too, including udp ${HOP_LO:+${HOP_LO}-${HOP_HI}, }${HY2_PORT}/${TUIC_PORT}."
echo
echo "Done."
