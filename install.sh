#!/usr/bin/env bash
#
# ScriptGain universal product installer.
#
#   curl -fsSL https://install.scriptgain.com | sudo bash -s -- <product> DOMAIN=your.domain [SSL=1 EMAIL=you@example.com]
#
# Provisions a fresh Debian/Ubuntu host with everything a ScriptGain product
# needs — PHP-FPM, MariaDB, nginx, Composer — downloads the app, migrates the
# database, wires up the scheduler + queue worker, and (optionally) issues a
# Let's Encrypt certificate. It then leaves the app at its one-time /setup
# wizard, where you create the admin account and enter your license key.
#
# Idempotent: safe to re-run. Tested: Ubuntu 22.04/24.04, Debian 12.
#
# Products: backup-mgr  guard-mgr  license-mgr  monitor-mgr  municipal-mgr  shop-mgr  storage-mgr  sync-mgr
set -euo pipefail

# ---------------------------------------------------------------------------
# Args + config (KEY=VALUE pairs may appear in any order after the product)
# ---------------------------------------------------------------------------
PRODUCT="${1:-}"; shift || true
for kv in "$@"; do case "$kv" in *=*) export "${kv?}";; esac; done

MIRROR="${MIRROR:-https://install.scriptgain.com}"     # where product tarballs + manifests live
VENDOR="${VENDOR:-https://scriptgain.com}"             # licensing API / storefront
DOMAIN="${DOMAIN:-}"
SSL="${SSL:-0}"
EMAIL="${EMAIL:-}"
S3_DOMAIN="${S3_DOMAIN:-}"    # dedicated S3 API hostname (StorageMGR); e.g. s3.example.com

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root (sudo)."
command -v apt-get >/dev/null || die "This installer targets Debian/Ubuntu (apt)."
[ -n "$PRODUCT" ] || die "Usage: install.sh <product> DOMAIN=your.domain [SSL=1 EMAIL=you@example.com]"
[ -n "$DOMAIN" ]  || die "Set DOMAIN=your.domain"

# ---------------------------------------------------------------------------
# Per-product manifest. Fetched from the mirror; falls back to a bundled copy
# under products/<product>.env when this script is run from a repo checkout.
# Defines: PRODUCT_NAME, PHP_VER, DB_NAME, DB_USER, APP_DIR, RELEASE_URL,
#          BOOTSTRAP_CMD (optional artisan command run after migrate).
# ---------------------------------------------------------------------------
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo /tmp)"
MANIFEST="$(mktemp)"
if curl -fsSL "${MIRROR}/products/${PRODUCT}.env" -o "$MANIFEST" 2>/dev/null; then :;
elif [ -f "${SRC_DIR}/products/${PRODUCT}.env" ]; then cp "${SRC_DIR}/products/${PRODUCT}.env" "$MANIFEST";
else die "Unknown product '${PRODUCT}' (no manifest at ${MIRROR}/products/${PRODUCT}.env)."; fi
# shellcheck disable=SC1090
. "$MANIFEST"

PHP_VER="${PHP_VER:-8.3}"
APP_DIR="${APP_DIR:-/var/www/${PRODUCT}}"
DB_NAME="${DB_NAME:-${PRODUCT//-/_}_db}"
DB_USER="${DB_USER:-${PRODUCT//-/_}}"
RELEASE_URL="${RELEASE_URL:-${MIRROR}/releases/${PRODUCT}-latest.tar.gz}"

log "Installing ${PRODUCT_NAME:-$PRODUCT} at https://${DOMAIN}"

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
log "Installing packages (php ${PHP_VER}, mariadb, nginx, composer)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y software-properties-common ca-certificates curl unzip git gnupg rsync openssl
if grep -qi ubuntu /etc/os-release; then
  add-apt-repository -y ppa:ondrej/php
  apt-get update -y
fi
apt-get install -y \
  "php${PHP_VER}-fpm" "php${PHP_VER}-cli" "php${PHP_VER}-mysql" "php${PHP_VER}-mbstring" \
  "php${PHP_VER}-xml" "php${PHP_VER}-curl" "php${PHP_VER}-zip" "php${PHP_VER}-bcmath" \
  "php${PHP_VER}-intl" "php${PHP_VER}-gd" \
  mariadb-server nginx
if ! command -v composer >/dev/null; then
  curl -sS https://getcomposer.org/installer | "php${PHP_VER}" -- --install-dir=/usr/local/bin --filename=composer
fi

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
log "Creating database ${DB_NAME}"
DB_PASS="${DB_PASS:-$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)}"
mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1'; FLUSH PRIVILEGES;"

# ---------------------------------------------------------------------------
# Application code
#   Primary source is the product's PUBLIC git repo (source-available; the
#   license — not code secrecy — is the commercial gate, and the value-
#   delivering Go agents enforce it). Falls back to a release tarball if the
#   manifest sets RELEASE_URL and no REPO.
# ---------------------------------------------------------------------------
mkdir -p "$APP_DIR"
if [ -n "${REPO:-}" ]; then
  log "Cloning application from ${REPO} (${REF:-main})"
  if [ -d "$APP_DIR/.git" ]; then
    git config --global --add safe.directory "$APP_DIR"
    git -C "$APP_DIR" fetch --depth 1 origin "${REF:-main}"
    git -C "$APP_DIR" reset --hard "origin/${REF:-main}"
  else
    git clone --depth 1 --branch "${REF:-main}" "$REPO" "$APP_DIR" \
      || die "Could not clone ${REPO}"
  fi
else
  log "Downloading application from ${RELEASE_URL}"
  TARBALL="$(mktemp)"
  curl -fSL "$RELEASE_URL" -o "$TARBALL" || die "Could not download the release tarball."
  tar -xzf "$TARBALL" -C "$APP_DIR" --strip-components=1
  rm -f "$TARBALL"
fi
cd "$APP_DIR"
composer install --no-dev --optimize-autoloader --no-interaction
# Framework cache dirs must exist before config:cache (config/view.php realpath()s
# storage/framework/views; a missing dir caches an empty path -> runtime 500).
mkdir -p storage/framework/cache/data storage/framework/sessions storage/framework/views storage/logs bootstrap/cache

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
log "Configuring environment"
[ -f .env ] || cp .env.example .env 2>/dev/null || touch .env
set_env() { grep -q "^$1=" .env && sed -i "s|^$1=.*|$1=$2|" .env || echo "$1=$2" >> .env; }
set_env APP_ENV production
set_env APP_DEBUG false
set_env APP_URL "https://${DOMAIN}"
set_env DB_CONNECTION mysql
set_env DB_HOST 127.0.0.1
set_env DB_PORT 3306
set_env DB_DATABASE "$DB_NAME"
set_env DB_USERNAME "$DB_USER"
set_env DB_PASSWORD "$DB_PASS"
set_env SESSION_DRIVER database
set_env QUEUE_CONNECTION database
set_env CACHE_STORE database
set_env LICENSE_ENDPOINT "${VENDOR}/v1"
# StorageMGR: serve the S3 API at the dedicated host's root so aws/mc connect
# with --endpoint-url https://${S3_DOMAIN} (no path component).
if [ "${S3_ENDPOINT:-0}" = "1" ] && [ -n "$S3_DOMAIN" ]; then
  set_env STORAGE_S3_DOMAIN "$S3_DOMAIN"
fi
grep -q "^APP_KEY=base64" .env || "php${PHP_VER}" artisan key:generate --force

# ---------------------------------------------------------------------------
# Migrate + product bootstrap
# ---------------------------------------------------------------------------
log "Migrating database"
"php${PHP_VER}" artisan migrate --force
if [ -n "${BOOTSTRAP_CMD:-}" ]; then
  log "Bootstrapping (${BOOTSTRAP_CMD})"
  "php${PHP_VER}" artisan ${BOOTSTRAP_CMD} || echo "bootstrap step reported a warning; continuing."
fi
"php${PHP_VER}" artisan config:cache
"php${PHP_VER}" artisan route:cache

log "Setting permissions"
mkdir -p "$APP_DIR/storage/framework/cache/data" "$APP_DIR/storage/framework/sessions" "$APP_DIR/storage/framework/views" "$APP_DIR/storage/logs" "$APP_DIR/bootstrap/cache"
chown -R www-data:www-data "$APP_DIR"
find "$APP_DIR/storage" "$APP_DIR/bootstrap/cache" -type d -exec chmod 775 {} \;

# ---------------------------------------------------------------------------
# nginx
# ---------------------------------------------------------------------------
log "Configuring nginx"
cat > "/etc/nginx/sites-available/${PRODUCT}.conf" <<NGINX
server {
    listen 80;
    server_name ${DOMAIN};
    root ${APP_DIR}/public;
    index index.php;
    charset utf-8;
    client_max_body_size 128M;
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php\$ {
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }
    location ~ /\.(?!well-known).* { deny all; }
}
NGINX
ln -sf "/etc/nginx/sites-available/${PRODUCT}.conf" "/etc/nginx/sites-enabled/${PRODUCT}.conf"

# ---------------------------------------------------------------------------
# S3 API endpoint (StorageMGR). The manifest sets S3_ENDPOINT=1; the operator
# supplies S3_DOMAIN=s3.example.com. S3 clients (aws, mc) need the API served
# at the ROOT of a hostname, not under a path, so this is a separate vhost.
#
# The three settings below are load-bearing and each cost real debugging:
#   - no "index index.php": nginx would answer PUT/DELETE with 405 before PHP.
#   - client_max_body_size 0: object uploads are unbounded.
#   - do NOT set fastcgi_request_buffering off: it delivers empty bodies to PHP
#     and every upload silently stores zero bytes.
# ---------------------------------------------------------------------------
if [ "${S3_ENDPOINT:-0}" = "1" ] && [ -n "$S3_DOMAIN" ]; then
  log "Configuring S3 API endpoint at ${S3_DOMAIN}"
  cat > "/etc/nginx/sites-available/${PRODUCT}-s3.conf" <<NGINX
server {
    listen 80;
    server_name ${S3_DOMAIN};
    root ${APP_DIR}/public;
    charset utf-8;
    client_max_body_size 0;
    location / { try_files /nonexistent /index.php\$is_args\$args; }
    location ~ \.php\$ {
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_read_timeout 3600;
        include fastcgi_params;
    }
    location ~ /\.(?!well-known).* { deny all; }
}
NGINX
  ln -sf "/etc/nginx/sites-available/${PRODUCT}-s3.conf" "/etc/nginx/sites-enabled/${PRODUCT}-s3.conf"
fi

nginx -t && systemctl reload nginx

# Open web ports if ufw is active (the app + Let's Encrypt need 80/443 reachable).
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp  >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Scheduler (cron) + queue worker (systemd)
# ---------------------------------------------------------------------------
log "Installing scheduler + queue worker"
CRON_LINE="* * * * * cd ${APP_DIR} && php${PHP_VER} artisan schedule:run >> /dev/null 2>&1"
# Match on this product's APP_DIR, not on "artisan schedule:run": several
# ScriptGain products can share a host, and a broad match would strip their
# scheduler lines too.
NEW_CRON="$( (crontab -l 2>/dev/null || true) | grep -vF "cd ${APP_DIR} &&" || true; echo "$CRON_LINE" )"
printf '%s\n' "$NEW_CRON" | crontab - || true
cat > "/etc/systemd/system/${PRODUCT}-queue.service" <<UNIT
[Unit]
Description=${PRODUCT_NAME:-$PRODUCT} queue worker
After=network.target mariadb.service

[Service]
User=www-data
Restart=always
ExecStart=/usr/bin/php${PHP_VER} ${APP_DIR}/artisan queue:work --sleep=3 --tries=3

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now "${PRODUCT}-queue" || echo "queue worker did not start; check: systemctl status ${PRODUCT}-queue"

# ---------------------------------------------------------------------------
# Let's Encrypt (optional)
# ---------------------------------------------------------------------------
if [ "$SSL" = "1" ]; then
  log "Issuing Let's Encrypt certificate"
  apt-get install -y certbot python3-certbot-nginx
  # Cover the S3 hostname in the same cert when present, so both the console and
  # the S3 API get HTTPS in one shot.
  CERT_DOMAINS=(-d "$DOMAIN")
  if [ "${S3_ENDPOINT:-0}" = "1" ] && [ -n "$S3_DOMAIN" ]; then
    CERT_DOMAINS+=(-d "$S3_DOMAIN")
  fi
  certbot --nginx "${CERT_DOMAINS[@]}" --non-interactive --agree-tos ${EMAIL:+-m "$EMAIL"} --redirect \
    || echo "certbot failed; run 'certbot --nginx ${CERT_DOMAINS[*]}' manually once DNS points here."
fi

SCHEME="http"; [ "$SSL" = "1" ] && SCHEME="https"
log "Done"
cat <<DONE

  ${PRODUCT_NAME:-$PRODUCT} is installed.

  Finish setup in your browser:

      ${SCHEME}://${DOMAIN}/setup

  There you'll create the admin account and enter your license key
  (buy one at ${VENDOR}/products/${STORE_SLUG:-$PRODUCT}). The database password
  is stored in ${APP_DIR}/.env.
DONE

if [ "${S3_ENDPOINT:-0}" = "1" ] && [ -n "$S3_DOMAIN" ]; then
cat <<S3DONE

  S3 API endpoint: ${SCHEME}://${S3_DOMAIN}
  Point an S3 client at it once you've created an access key in the console:

      aws --endpoint-url ${SCHEME}://${S3_DOMAIN} s3 ls
      mc alias set myhost ${SCHEME}://${S3_DOMAIN} ACCESS_KEY SECRET_KEY

  Notes:
    - ${S3_DOMAIN} must resolve to this server (its own DNS A record).
    - Do NOT put the S3 hostname behind a proxying CDN (e.g. Cloudflare's
      orange cloud): it strips ETag headers and breaks multipart uploads.
    - The AWS CLI needs path-style addressing: set 'addressing_style = path'
      under [default] s3 in ~/.aws/config.
S3DONE
fi
