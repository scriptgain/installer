# Installing BackupMGR

BackupMGR is a self-hosted backup platform (control panel + lightweight Go agents). The installer provisions everything on a fresh **Debian 12** or **Ubuntu 22.04/24.04** server and leaves you at a one-time setup wizard.

## Requirements

- A fresh Debian/Ubuntu server (root/sudo access)
- A domain pointed at the server's IP (an `A` record)
- Ports 80/443 open
- A BackupMGR license key — buy one at <https://scriptgain.com/products/backup-manager>

## One-line install

```bash
curl -fsSL https://install.scriptgain.com | sudo bash -s -- backup-manager DOMAIN=backup.yourcompany.com SSL=1 EMAIL=you@yourcompany.com
```

What it does:

1. Installs PHP-FPM, MariaDB, nginx, and Composer.
2. Creates the database and a dedicated DB user.
3. Downloads the BackupMGR release and installs dependencies.
4. Writes `.env`, generates the app key, runs migrations, bootstraps.
5. Configures the nginx vhost, the scheduler (cron), and the queue worker (systemd).
6. With `SSL=1`, issues a Let's Encrypt certificate for your domain.

Options (append as `KEY=VALUE`):

| Key | Default | Purpose |
|-----|---------|---------|
| `DOMAIN` | *(required)* | The hostname BackupMGR runs on |
| `SSL` | `0` | `1` to issue a Let's Encrypt cert |
| `EMAIL` | *(none)* | Contact email for Let's Encrypt |
| `APP_DIR` | `/var/www/backupmgr` | Install location |
| `PHP_VER` | `8.3` | PHP version |
| `RELEASE_URL` | latest | Pin a specific release tarball |

## Finish setup

Open the URL the installer prints:

```
https://backup.yourcompany.com/setup
```

The one-time wizard walks you through:

1. **Create your admin account.**
2. **Enter your license key.** BackupMGR validates it against `scriptgain.com/v1/validate` and verifies the RSA-signed response against its embedded public key. (No internet at install time? You can finish and add the key later — the panel never locks you out; it shows a banner until a valid key is present.)

That's it — you're in.

## Add a host to back up

From the BackupMGR admin, create a host to get an enrollment token, then on the target machine:

```bash
curl -fsSL https://backup.yourcompany.com/downloads/agent-install.sh | sudo bash -s -- https://backup.yourcompany.com <enroll-token>
```

The agent (bundled with kopia) polls the master outbound only — no inbound ports to open on the host.

## Re-running / upgrading

The installer is idempotent — re-running it upgrades the code and re-migrates safely. To upgrade only:

```bash
cd /var/www/backupmgr && sudo -u www-data php8.3 artisan down
# fetch + extract the new release over the app dir, then:
sudo -u www-data composer install --no-dev -o
sudo -u www-data php8.3 artisan migrate --force
sudo -u www-data php8.3 artisan up
```

## Troubleshooting

- **License shows a banner** — the key hasn't validated yet. Check outbound HTTPS to `scriptgain.com`, then re-check at Settings → License.
- **certbot failed** — DNS wasn't pointing at the server yet. Run `sudo certbot --nginx -d backup.yourcompany.com` once it is.
- **502 / white page** — check `systemctl status php8.3-fpm nginx` and `storage/logs/laravel.log`.
