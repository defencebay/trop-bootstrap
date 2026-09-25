# Advanced operator recipes

Start with the [visual walkthrough](../README.md) for the managed install, upgrade, configuration apply, and restart flows. These recipes are for a deliberate checkpoint or a host whose operator CLI is older.

## Download a verified bundle to a custom directory

Use `--dest` when you need to inspect or transfer one verified release bundle. It changes the bundle destination, **not** the managed installation root.

```bash
mkdir -p "$HOME/trop-bundles"
./trop-bootstrap --release <release> \
  --dest "$HOME/trop-bundles/<release>" --fetch-only
cd "$HOME/trop-bundles/<release>"
ls trop-install.sh SHA256SUMS-* zarf-package-trop-platform-*.tar.zst
```

Replace `<release>` with a complete stable tag offered for this host's architecture. `--fetch-only` does not deploy. A custom directory is operator-owned; it does not create or move `/opt/trop/current`. If you later run its installer there, configuration remains local and you own future updates and access protection. An **existing managed installation must upgrade into** `/opt/trop/releases/<release>`; omit `--dest` for it.

## Pause a managed first install after download

```bash
./trop-bootstrap --release <release> --fetch-only
cd /opt/trop/releases/<release>
ls zarf-package-trop-platform-*.tar.zst zarf-init-*.tar.zst
sudo ./trop-install.sh setup
sudo ./trop-install.sh deploy zarf-package-trop-platform-<arch>-<release>.tar.zst \
  --init-package zarf-init-<arch>-<version>.tar.zst
```

Use the exact architecture and filenames printed by the launcher, rather than typing the angle-bracket placeholders. This is for a **first** installation. Setup asks for the profile, hostnames, LAN address, administrator password, and optional host integrations. Review its plan before deployment.

## Upgrade when the installed operator CLI is old

An older `trop` may lack `upgrade` or `--release`. Download a fresh public launcher into any working directory:

```bash
mkdir -p "$HOME/trop-bootstrap" && cd "$HOME/trop-bootstrap"
curl -fL https://github.com/defencebay/trop-bootstrap/releases/latest/download/trop-bootstrap \
  -o trop-bootstrap
chmod +x trop-bootstrap
./trop-bootstrap --release <release>
```

The launcher detects a healthy managed installation and imports `/etc/trop`; do **not** run `setup` again. Use the recommended `/opt/trop/releases/<release>` destination. If it reports an ambiguous or degraded state, diagnose that state before deploying a different release.

For an intentionally manual checkpoint after a successful managed fetch:

```bash
./trop-bootstrap --release <release> --fetch-only
cd /opt/trop/releases/<release>
sudo ./trop-install.sh update zarf-package-trop-platform-<arch>-<release>.tar.zst
```

Again, replace placeholders with the exact signed package filename printed by bootstrap. A normal connected upgrade is simpler through `trop upgrade` or the guided launcher.

## Encrypted configuration and diagnostics

If `/etc/trop/zarf-config.enc.yaml` is the active source, use your site's SOPS/age workflow and keep decrypted material out of shared directories. After an edit, a compatible operator CLI can apply the active release's configuration:

```bash
trop config apply
trop health
```

To inspect a failed operation:

```bash
trop-doctor failing-pods
trop-doctor debug-bundle
sudo cat /opt/trop/operation-state
```

On an older release without a compatible `trop config apply`, upgrade the tooling/release first. The launcher verifies cached signed assets on retry and prints a resume command if it stops after download.
