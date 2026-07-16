# ScriptGain Installers

One-command installers for self-hosting [ScriptGain](https://scriptgain.com) products on Debian/Ubuntu. Each installer provisions everything the product needs — PHP-FPM, MariaDB, nginx, Composer — downloads the app, migrates the database, wires up the scheduler and queue worker, and (optionally) issues a Let's Encrypt certificate. It then hands off to the product's one-time `/setup` wizard, where you create the admin account and enter your license key.

## Quick start

```bash
curl -fsSL https://install.scriptgain.com | sudo bash -s -- <product> DOMAIN=your.domain SSL=1 EMAIL=you@example.com
```

Then open `https://your.domain/setup`.

## Products

| Product | Command argument | Docs | Status |
|---------|------------------|------|--------|
| **BackupMGR** — self-hosted backup platform | `backup-mgr` | [docs](docs/backup-manager.md) | ✅ available |
| **LicenseMGR** — licensing / entitlement server | `license-mgr` | — | ✅ available |
| **MonitorMGR** — monitoring & status pages | `monitor-mgr` | — | ✅ available |
| **StorageMGR** — S3-compatible object storage | `storage-mgr` | — | ✅ available |
| **CertMGR** — certificate management | `cert-mgr` | — | ✅ available |
| **SyncMGR** — continuous directory sync | `sync-mgr` | — | ✅ available |

## Requirements

- Fresh **Debian 12** or **Ubuntu 22.04/24.04** host with root/sudo
- A domain with an `A` record pointing at the server
- Ports 80/443 open
- A license key for the product (buy at `https://scriptgain.com/products/<product>`)

## How it works

```
curl … | bash -s -- <product> DOMAIN=…
   │
   ├─ install.sh          universal installer (OS detect, deps, db, app, nginx, ssl, systemd)
   ├─ products/<p>.env    per-product manifest (name, php version, db, release URL, bootstrap cmd)
   └─ docs/<p>.md         install docs
        │
        ▼
   https://DOMAIN/setup   one-time wizard: admin account + license validation
```

- `install.sh` is product-agnostic; it reads `products/<product>.env` for the specifics.
- App code is pulled from a **signed release tarball** hosted on the mirror (`install.scriptgain.com`), not from this repo — this repo holds only the installers, manifests, and docs.
- Licensing responses are **RSA-signed** and verified locally by each install (see each product's setup step).

## Adding a product

1. Add `products/<product>.env` (copy `products/backup-manager.env`; set name, DB, `RELEASE_URL`, `BOOTSTRAP_CMD`).
2. Publish the product's release tarball to the mirror at the `RELEASE_URL` path.
3. Add `docs/<product>.md`.
4. Add a row to the table above.

## Overrides

Any manifest value can be overridden at runtime, e.g. pin a version or change the install path:

```bash
curl -fsSL https://install.scriptgain.com | sudo bash -s -- backup-manager \
  DOMAIN=backup.example.com SSL=1 EMAIL=you@example.com \
  RELEASE_URL=https://install.scriptgain.com/releases/backup-manager-1.0.0.tar.gz \
  APP_DIR=/srv/backupmgr
```
