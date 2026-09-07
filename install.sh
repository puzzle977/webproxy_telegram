#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

# ============================================================
# Telegram WEB Proxy installer
#
# Clean Ubuntu 22.04+ / Debian 12+ x86_64 VPS
#
# Uses:
#   https://github.com/telegramdesktop/tproxy-server
#
# Architecture:
#
# Internet :80/:443
#       |
#     Caddy
#       |
# 127.0.0.1:8080
# tproxy-server
#       |
# 127.0.0.1:2398
# official MTProxy
#
# Includes workarounds for current upstream umask issues.
# ============================================================


REPOSITORY="/opt/tproxy-server"
SECRET_FILE="/root/tproxy-web-secret.txt"

DOMAIN=""
EMAIL=""
SITE_DIR=""
AUTO_SITE=0


# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

log() {
    echo
    echo "============================================================"
    echo "==> $*"
    echo "============================================================"
}

die() {
    echo
    echo "ERROR: $*" >&2
    exit 1
}

on_error() {

    local rc=$?

    echo
    echo "============================================================"
    echo "INSTALLATION FAILED"
    echo "============================================================"
    echo
    echo "Exit code: $rc"
    echo
    echo "Diagnostics:"
    echo
    echo "systemctl is-active caddy mtproxy tproxy-server tproxy-firewall"
    echo
    echo "curl -i http://127.0.0.1:8081/readyz"
    echo
    echo "journalctl -u caddy -u mtproxy -u tproxy-server --since '-10 minutes' --no-pager"
    echo
    echo "ss -ltnp | grep -E ':(80|443|8080|8081|2398|8888)\b'"
    echo
    echo "Do NOT publish:"
    echo "  systemctl status mtproxy"
    echo
    echo "because its command line can contain the proxy secret."
    echo

    exit "$rc"
}

trap on_error ERR


# ------------------------------------------------------------
# Root / OS
# ------------------------------------------------------------

[[ "$EUID" -eq 0 ]] || die "Run this script as root."

[[ "$(uname -m)" == "x86_64" ]] || \
    die "x86_64 VPS is required."

[[ -r /etc/os-release ]] || \
    die "Cannot detect Linux distribution."

. /etc/os-release

case "${ID:-}" in

    ubuntu)

        dpkg --compare-versions "${VERSION_ID}" ge "22.04" || \
            die "Ubuntu 22.04 or newer is required."

        ;;

    debian)

        dpkg --compare-versions "${VERSION_ID}" ge "12" || \
            die "Debian 12 or newer is required."

        ;;

    *)

        die "Only Ubuntu 22.04+ and Debian 12+ are supported."

        ;;
esac


# ------------------------------------------------------------
# Initial packages
# ------------------------------------------------------------

log "Installing pre-flight tools"

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    dnsutils \
    iproute2 \
    openssl \
    nftables


# ------------------------------------------------------------
# Interactive DOMAIN
# ------------------------------------------------------------

echo
echo "Telegram WEB Proxy installer"
echo

while true; do

    read -r -p "WEB Proxy domain (example: proxy.example.com): " DOMAIN

    DOMAIN="${DOMAIN,,}"

    if [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] &&
       [[ "$DOMAIN" == *.* ]]; then

        break
    fi

    echo "Invalid domain."
    echo "Use a lowercase ASCII hostname such as proxy.example.com."
done


# ------------------------------------------------------------
# Interactive EMAIL
# ------------------------------------------------------------

while true; do

    read -r -p "Email for Let's Encrypt / ACME: " EMAIL

    if [[ "$EMAIL" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        break
    fi

    echo "Invalid email."
done


# ------------------------------------------------------------
# Existing installation check
# ------------------------------------------------------------

if [[ -e /etc/tproxy-server/config.json ]] ||
   systemctl list-unit-files 2>/dev/null |
   grep -q '^tproxy-server.service'; then

    die "An existing tproxy-server installation was detected."
fi


# ------------------------------------------------------------
# Ports
# ------------------------------------------------------------

log "Checking ports"

port_is_busy() {

    local port="$1"

    ss -H -ltn |
    awk '{print $4}' |
    grep -Eq ":${port}$"
}

for port in 80 443; do

    if port_is_busy "$port"; then

        echo
        echo "TCP/$port is already occupied:"
        ss -ltnp | grep -E ":${port}\b" || true

        die "Ports 80 and 443 must be free on a clean server."
    fi

done

echo "80/tcp  : free"
echo "443/tcp : free"


# ------------------------------------------------------------
# DNS IPv4
# ------------------------------------------------------------

log "Checking DNS"

PUBLIC_IPV4="$(
    curl \
        -4 \
        -fsS \
        --connect-timeout 10 \
        --max-time 15 \
        https://api.ipify.org
)"

[[ -n "$PUBLIC_IPV4" ]] || \
    die "Could not determine VPS public IPv4."

DNS_IPV4="$(
    dig +short A "$DOMAIN" |
    sort -u
)"

echo "VPS public IPv4:"
echo "  $PUBLIC_IPV4"
echo

echo "DNS A records:"
printf '  %s\n' $DNS_IPV4

if ! grep -Fxq "$PUBLIC_IPV4" <<<"$DNS_IPV4"; then

    echo
    echo "Create/update the DNS A record:"
    echo
    echo "  $DOMAIN -> $PUBLIC_IPV4"
    echo

    die "DNS A record does not point to this VPS."
fi


# ------------------------------------------------------------
# DNS IPv6
# ------------------------------------------------------------

DNS_IPV6="$(
    dig +short AAAA "$DOMAIN" |
    sort -u
)"

if [[ -n "$DNS_IPV6" ]]; then

    echo
    echo "AAAA record detected:"
    printf '  %s\n' $DNS_IPV6
    echo

    PUBLIC_IPV6="$(
        curl \
            -6 \
            -fsS \
            --connect-timeout 5 \
            --max-time 10 \
            https://api64.ipify.org \
            2>/dev/null || true
    )"

    if [[ -z "$PUBLIC_IPV6" ]]; then

        echo "The domain has an AAAA record, but this VPS"
        echo "does not appear to have working public IPv6."
        echo

        die "Remove the AAAA record or configure IPv6 first."
    fi

    echo "VPS public IPv6:"
    echo "  $PUBLIC_IPV6"

    if ! grep -Fxqi "$PUBLIC_IPV6" <<<"$DNS_IPV6"; then

        echo
        echo "AAAA does not match the VPS public IPv6."

        die "Fix or remove the AAAA record first."
    fi
fi


# ------------------------------------------------------------
# Site
# ------------------------------------------------------------

log "Public website"

echo
echo "tproxy-server should serve a normal HTTPS website."
echo
echo "Recommended:"
echo "  provide your own static site containing index.html."
echo
echo "If you press Enter, a minimal unique site will be generated."
echo

read -r -p "Static site directory [Enter = generate automatically]: " SITE_DIR

if [[ -n "$SITE_DIR" ]]; then

    [[ -d "$SITE_DIR" ]] || \
        die "Directory does not exist: $SITE_DIR"

    [[ -f "$SITE_DIR/index.html" ]] || \
        die "$SITE_DIR must contain index.html"

    SITE_DIR="$(
        cd "$SITE_DIR"
        pwd -P
    )"

else

    AUTO_SITE=1

    SITE_DIR="$(
        mktemp -d /root/tproxy-public-site.XXXXXX
    )"

    SITE_ID="$(openssl rand -hex 8)"

    cat >"$SITE_DIR/style.css" <<'EOF'
:root {
    font-family: system-ui, -apple-system, BlinkMacSystemFont,
        "Segoe UI", sans-serif;
    line-height: 1.6;
}

body {
    max-width: 760px;
    margin: 4rem auto;
    padding: 0 1.5rem;
}

header {
    margin-bottom: 3rem;
}

nav a {
    margin-right: 1rem;
}

footer {
    margin-top: 4rem;
    opacity: .6;
    font-size: .85rem;
}
EOF


    cat >"$SITE_DIR/favicon.svg" <<EOF
<svg
 xmlns="http://www.w3.org/2000/svg"
 viewBox="0 0 64 64">
 <rect
  width="64"
  height="64"
  rx="14"
  fill="#303030"/>
 <circle
  cx="32"
  cy="32"
  r="15"
  fill="#ffffff"/>
</svg>
EOF


    cat >"$SITE_DIR/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta
 name="viewport"
 content="width=device-width,initial-scale=1">
<title>${DOMAIN}</title>
<link
 rel="stylesheet"
 href="/style.css">
<link
 rel="icon"
 href="/favicon.svg">
</head>
<body>

<header>
<nav>
<a href="/">Home</a>
<a href="/about.html">About</a>
<a href="/status.html">Status</a>
</nav>
</header>

<main>
<h1>${DOMAIN}</h1>
<p>Welcome.</p>
<p>This web service is currently online.</p>
</main>

<footer>
Service ID: ${SITE_ID}
</footer>

</body>
</html>
EOF


    cat >"$SITE_DIR/about.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta
 name="viewport"
 content="width=device-width,initial-scale=1">
<title>About</title>
<link
 rel="stylesheet"
 href="/style.css">
<link
 rel="icon"
 href="/favicon.svg">
</head>
<body>

<header>
<nav>
<a href="/">Home</a>
<a href="/about.html">About</a>
<a href="/status.html">Status</a>
</nav>
</header>

<main>
<h1>About</h1>
<p>Information service for ${DOMAIN}.</p>
</main>

<footer>
Service ID: ${SITE_ID}
</footer>

</body>
</html>
EOF


    cat >"$SITE_DIR/status.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta
 name="viewport"
 content="width=device-width,initial-scale=1">
<title>Status</title>
<link
 rel="stylesheet"
 href="/style.css">
<link
 rel="icon"
 href="/favicon.svg">
</head>
<body>

<header>
<nav>
<a href="/">Home</a>
<a href="/about.html">About</a>
<a href="/status.html">Status</a>
</nav>
</header>

<main>
<h1>Status</h1>
<p>Service operational.</p>
</main>

<footer>
Service ID: ${SITE_ID}
</footer>

</body>
</html>
EOF


    cat >"$SITE_DIR/404.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta
 name="viewport"
 content="width=device-width,initial-scale=1">
<title>Not found</title>
<link
 rel="stylesheet"
 href="/style.css">
</head>
<body>

<h1>404</h1>
<p>The requested page was not found.</p>
<p><a href="/">Home</a></p>

<footer>
Service ID: ${SITE_ID}
</footer>

</body>
</html>
EOF


    chmod 0755 "$SITE_DIR"
    chmod 0644 "$SITE_DIR"/*

    echo
    echo "Generated site:"
    echo "  $SITE_DIR"
fi


# ------------------------------------------------------------
# Secret
# ------------------------------------------------------------

log "Generating WEB Proxy secret"

if [[ -e "$SECRET_FILE" ]]; then
    die "$SECRET_FILE already exists. Refusing to overwrite it."
fi

openssl rand -hex 16 >"$SECRET_FILE"

chmod 0600 "$SECRET_FILE"

SECRET="$(
    tr -d '\r\n' <"$SECRET_FILE"
)"

[[ "$SECRET" =~ ^[0-9a-f]{32}$ ]] || \
    die "Failed to generate a valid secret."

echo "Secret generated."


# ------------------------------------------------------------
# Confirmation
# ------------------------------------------------------------

echo
echo "============================================================"
echo "INSTALLATION SUMMARY"
echo "============================================================"
echo
echo "Domain:"
echo "  $DOMAIN"
echo
echo "ACME email:"
echo "  $EMAIL"
echo
echo "Static site:"
echo "  $SITE_DIR"
echo
echo "Public IPv4:"
echo "  $PUBLIC_IPV4"
echo
echo "The secret has been generated but is not displayed yet."
echo

read -r -p "Continue installation? [Y/n]: " ANSWER

ANSWER="${ANSWER:-Y}"

case "$ANSWER" in
    y|Y|yes|YES)
        ;;
    *)
        echo "Cancelled."
        exit 0
        ;;
esac


# ------------------------------------------------------------
# Clone official project
# ------------------------------------------------------------

log "Downloading official telegramdesktop/tproxy-server"

if [[ -e "$REPOSITORY" ]]; then

    mv \
        "$REPOSITORY" \
        "${REPOSITORY}.old.$(date +%Y%m%d-%H%M%S)"
fi

git clone \
    --depth 1 \
    https://github.com/telegramdesktop/tproxy-server.git \
    "$REPOSITORY"

COMMIT="$(
    git -C "$REPOSITORY" rev-parse HEAD
)"

echo "$COMMIT" > /root/tproxy-server-commit.txt

echo
echo "Commit:"
echo "  $COMMIT"


# ------------------------------------------------------------
# Patch current upstream fresh-install problems
# ------------------------------------------------------------

log "Applying fresh-install compatibility fixes"

INSTALLER="$REPOSITORY/deploy/install.sh"

[[ -f "$INSTALLER" ]] || \
    die "Official deploy/install.sh was not found."

cp -a \
    "$INSTALLER" \
    "$INSTALLER.original"


# ------------------------------------------------------------
# Workaround #1
#
# The official installer uses umask 077.
# One current test is umask-dependent.
#
# Run only Go tests with umask 022.
# The rest of the official installer keeps umask 077.
# ------------------------------------------------------------

PATCH_TMP="$(
    mktemp /tmp/tproxy-install.XXXXXX
)"

awk '
{
    if ($0 == "(cd \"$repository\" && \"$go_binary\" test ./...)") {
        print "(umask 022; cd \"$repository\" && \"$go_binary\" test ./...)"
    } else {
        print
    }
}
' "$INSTALLER" >"$PATCH_TMP"

mv "$PATCH_TMP" "$INSTALLER"

chmod 0755 "$INSTALLER"


# ------------------------------------------------------------
# Workaround #2
#
# Under umask 077 MTProxy may be built under:
#
# /opt/MTProxy/objs
# /opt/MTProxy/objs/bin
#
# with 0700 directories.
#
# mtproxy.service then cannot traverse those directories,
# resulting in systemd status=203/EXEC.
# ------------------------------------------------------------

PATCH_TMP="$(
    mktemp /tmp/tproxy-install.XXXXXX
)"

awk '
{
    print

    if ($0 == "\"$repository/deploy/install-mtproxy.sh\"") {

        print ""
        print "# Local compatibility fix for MTProxy permissions."
        print "chmod 0755 /opt/MTProxy"
        print "chmod 0755 /opt/MTProxy/objs"
        print "chmod 0755 /opt/MTProxy/objs/bin"
        print "chmod 0755 /opt/MTProxy/objs/bin/mtproto-proxy"
    }
}
' "$INSTALLER" >"$PATCH_TMP"

mv "$PATCH_TMP" "$INSTALLER"

chmod 0755 "$INSTALLER"


# ------------------------------------------------------------
# Show whether the patches matched current upstream
# ------------------------------------------------------------

echo
echo "Compatibility patch status:"

if grep -Fq \
    '(umask 022; cd "$repository" && "$go_binary" test ./...)' \
    "$INSTALLER"; then

    echo "  Go test umask workaround: enabled"
else

    echo "  Go test line differs from known upstream version."
    echo "  Assuming upstream has changed/fixed it."
fi

if grep -Fq \
    'chmod 0755 /opt/MTProxy/objs/bin' \
    "$INSTALLER"; then

    echo "  MTProxy permission workaround: enabled"
else

    die "Could not apply MTProxy permission workaround."
fi


# ------------------------------------------------------------
# UFW
# ------------------------------------------------------------

if command -v ufw >/dev/null 2>&1 &&
   ufw status 2>/dev/null |
   head -n1 |
   grep -qi 'active'; then

    log "Opening TCP 80/443 in UFW"

    ufw allow 80/tcp
    ufw allow 443/tcp
fi


# Ensure public site path is accessible by tproxy-server before starting services
chmod 0755 "$(dirname "$SITE_DIR")"
chmod 0755 "$SITE_DIR"
chmod 0644 "$SITE_DIR"/*

# ------------------------------------------------------------
# Official installation
# ------------------------------------------------------------

log "Running official tproxy-server installer"

# Do NOT pass the secret through --secret.
#
# The official installer asks for it through stdin.
# This keeps the secret out of shell history and process args.

printf '%s\n' "$SECRET" |
"$INSTALLER" \
    --hostname "$DOMAIN" \
    --email "$EMAIL" \
    --site-dir "$SITE_DIR"


# ------------------------------------------------------------
# Enforce permissions after installation too
# ------------------------------------------------------------

log "Checking MTProxy permissions"

if [[ -f /opt/MTProxy/objs/bin/mtproto-proxy ]]; then

    chmod 0755 /opt/MTProxy
    chmod 0755 /opt/MTProxy/objs
    chmod 0755 /opt/MTProxy/objs/bin
    chmod 0755 /opt/MTProxy/objs/bin/mtproto-proxy

    chown root:root \
        /opt/MTProxy/objs/bin/mtproto-proxy
fi


# ------------------------------------------------------------
# Restart / recover if necessary
# ------------------------------------------------------------

systemctl daemon-reload

systemctl reset-failed mtproxy 2>/dev/null || true

systemctl restart mtproxy

sleep 2

systemctl restart tproxy-server

systemctl restart caddy

sleep 2


# ------------------------------------------------------------
# Service checks
# ------------------------------------------------------------

log "Checking services"

FAILED=0

for service in \
    caddy \
    mtproxy \
    tproxy-server \
    tproxy-firewall
do

    if systemctl is-active --quiet "$service"; then

        echo "$service: active"

    else

        echo "$service: FAILED"
        FAILED=1
    fi
done


# ------------------------------------------------------------
# Relay readiness
# ------------------------------------------------------------

log "Checking tproxy-server readiness"

READY=0

for _ in $(seq 1 30); do

    if curl \
        -fsS \
        --max-time 3 \
        http://127.0.0.1:8081/readyz \
        >/dev/null 2>&1; then

        READY=1
        break
    fi

    sleep 1
done

if [[ "$READY" -eq 1 ]]; then

    echo "readyz: OK"

else

    echo "readyz: FAILED"
    FAILED=1
fi


# ------------------------------------------------------------
# Caddy HTTPS / ACME
# ------------------------------------------------------------

log "Waiting for HTTPS certificate"

HTTPS_OK=0

for _ in $(seq 1 45); do

    if curl \
        -fsS \
        --connect-timeout 5 \
        --max-time 10 \
        "https://${DOMAIN}/" \
        >/dev/null 2>&1; then

        HTTPS_OK=1
        break
    fi

    sleep 2
done

if [[ "$HTTPS_OK" -eq 1 ]]; then

    echo "HTTPS: OK"

else

    echo "HTTPS: FAILED"
    echo
    echo "Check:"
    echo "  DNS A/AAAA records"
    echo "  provider firewall"
    echo "  inbound TCP 80/443"

    FAILED=1
fi


# ------------------------------------------------------------
# Backend firewall
# ------------------------------------------------------------

log "Checking backend firewall"

if nft list table inet tproxy_backend >/dev/null 2>&1; then

    echo "Backend firewall: OK"

else

    echo "Backend firewall: FAILED"
    FAILED=1
fi


# ------------------------------------------------------------
# Ports
# ------------------------------------------------------------

log "Listening ports"

ss -ltnp |
grep -E ':(80|443|8080|8081|2398|8888)\b' ||
true


# ------------------------------------------------------------
# Final
# ------------------------------------------------------------

if [[ "$FAILED" -ne 0 ]]; then

    echo
    echo "============================================================"
    echo "INSTALLATION FINISHED WITH ERRORS"
    echo "============================================================"
    echo
    echo "Run:"
    echo
    echo "systemctl is-active caddy mtproxy tproxy-server tproxy-firewall"
    echo
    echo "curl -i http://127.0.0.1:8081/readyz"
    echo
    echo "journalctl -u caddy -u mtproxy -u tproxy-server --since '-10 minutes' --no-pager"
    echo

    exit 1
fi


echo
echo "============================================================"
echo "        TELEGRAM WEB PROXY INSTALLED SUCCESSFULLY"
echo "============================================================"
echo

echo "Hostname:"
echo "  $DOMAIN"
echo

echo "WEB Proxy Secret:"
echo "  $SECRET"
echo

echo "Secret file:"
echo "  $SECRET_FILE"
echo

echo "Telegram settings:"
echo
echo "  Proxy type : WEB"
echo "  Host       : $DOMAIN"
echo "  Key        : $SECRET"
echo

echo "Telegram link:"
echo
echo "  tg://webproxy?server=${DOMAIN}&secret=${SECRET}"
echo

echo "Alternative link:"
echo
echo "  https://t.me/webproxy?server=${DOMAIN}&secret=${SECRET}"
echo

echo "Website:"
echo
echo "  https://${DOMAIN}/"
echo

echo "Health check:"
echo
echo "  curl -f http://127.0.0.1:8081/readyz"
echo

echo "Services:"
echo
echo "  systemctl is-active caddy mtproxy tproxy-server tproxy-firewall"
echo

if [[ "$AUTO_SITE" -eq 1 ]]; then

    echo "NOTE:"
    echo "  A basic public website was generated automatically."
    echo "  For a long-term/public deployment, replace it with"
    echo "  your own distinctive static site."
    echo
fi

echo
echo "Installed tproxy-server commit:"
echo "  $COMMIT"
echo
