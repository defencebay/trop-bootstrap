# TROP Standalone: install, configure, upgrade

Run these commands **on the Ubuntu host that will run TROP**. You need internet
access, `curl`, `sudo`, and a TROP token supplied by DefenceBay. Enter the token
at a hidden prompt; never put it in a command argument or environment variable.

## Which command does what?

| Command | Use it for | Where it comes from |
| --- | --- | --- |
| `./trop-bootstrap` | First install, signed release download, exact online upgrade | Public launcher downloaded to any working directory |
| `trop` | Operator menu, status, health, guided upgrade, config apply | Installed after a managed install when operator tools are enabled |
| `trop-doctor` | Validation and diagnostics; `trop` is its short operator entry point | Installed with operator tools |
| `trop-install` | Release-local deploy/update, recovery, offline/manual operations | Symlink to `/opt/trop/current/trop-install.sh` in a managed install |

Use `./trop-bootstrap` for the first install and `trop` for normal operations
afterward. `trop-install` is the lower-level installer for a downloaded bundle
or recovery procedure. Global commands are present only if setup enabled
`INSTALL_OPERATOR_TOOLS=true`.

## Where will it install?

The directory from which you run `./trop-bootstrap` only holds the launcher.
It does **not** determine where TROP is installed. Keep the recommended
destination in the wizard:

| Path | Contents |
| --- | --- |
| `/opt/trop/releases/<release>` | Complete verified bundle: installer, Zarf tools, signed packages, checksums |
| `/opt/trop/current` | Symlink to the last release that passed the health gate |
| `/etc/trop/zarf-config.yaml` or `zarf-config.enc.yaml` | Private deployment configuration, outside release directories |
| `/usr/local/bin/trop`, `trop-doctor`, `trop-install` | Optional global operator commands |

For example, installing `r65-20260918` while your shell is in
`~/trop-bootstrap` creates `/opt/trop/releases/r65-20260918`, not a TROP
installation under your home directory. An upgrade adds a new release
directory, keeps the old one, and changes `current` only after health
validation. Workload data is separate from these release directories.

### A custom directory

`--dest` changes **where one verified bundle is downloaded**, not the managed
installation root. Use it for a self-managed checkpoint:

```bash
mkdir -p "$HOME/trop-bundles"
./trop-bootstrap --release r70-20260924 \
  --dest "$HOME/trop-bundles/r70-20260924" --fetch-only
ls "$HOME/trop-bundles/r70-20260924"
```

The custom directory remains operator-owned. It does not create or update
`/opt/trop/current`; running its installer later uses local config. A host
already using the managed `/opt/trop/current` layout must upgrade into
`/opt/trop/releases/<release>`, so **omit `--dest` for a normal upgrade**.
The launcher does not support moving the managed installation root with
`--dest`. See the [manual custom-directory example](docs/operator-examples.md)
before choosing this layout.

## First installation and setup

```bash
mkdir -p "$HOME/trop-bootstrap" && cd "$HOME/trop-bootstrap"
curl -fL https://github.com/defencebay/trop-bootstrap/releases/latest/download/trop-bootstrap \
  -o trop-bootstrap
chmod +x trop-bootstrap
./trop-bootstrap
```

The launcher recommends the latest complete stable release for this computer's
architecture and `/opt/trop/releases/<release>` as the destination. Paste the
token at its hidden prompt. Choose **configure and install** to continue into
`trop-install.sh setup`. Setup asks for the deployment profile, hostnames,
client-facing LAN IPv4, and administrator settings, then shows the plan before
deployment. On a multi-network host, select the address clients will actually
reach; the default-route address is only a suggestion.

Setup asks separately whether it may manage the marked TROP block in
`/etc/hosts` (`MANAGE_LOCAL_HOSTS`), install the TROP CA in host trust
(`INSTALL_HOST_CA`), and install global operator commands
(`INSTALL_OPERATOR_TOOLS`). Answer `true` only for the integrations you want.
Missing flags in an imported older config count as `false`. Required TROP
workloads and k3s/Zarf initialization are shown separately.

After the installer reports success:

```bash
readlink -f /opt/trop/current
trop status
trop health
trop-doctor install-validate
```

`install-validate` securely prompts for administrator credentials. If you set
`INSTALL_OPERATOR_TOOLS=false`, use the release-local installer and bundled
validation tools instead of expecting global `trop` commands.

### Pause after download and resume

```bash
./trop-bootstrap --release r70-20260924 --fetch-only
cd /opt/trop/releases/r70-20260924
sudo ./trop-install.sh setup
sudo ./trop-install.sh deploy zarf-package-trop-platform-amd64-r70-20260924.tar.zst \
  --init-package zarf-init-amd64-v0.70.1.tar.zst
```

These filenames are for an amd64 **first** install. Use the filenames printed
by the launcher on another architecture. On an already installed host, reuse
`/etc/trop` and run `update` instead of `setup` and `deploy`.

## Upgrade an installed host

For a guided connected upgrade, run `trop upgrade` or select **Upgrade TROP**
from the `trop` menu. With a compatible operator tool, select an exact release:

```bash
trop upgrade --release r70-20260924
readlink -f /opt/trop/current
trop health
```

If the installed `trop` predates the `--release` option, download the current
public launcher and use `./trop-bootstrap --release r70-20260924` instead.
It detects the active managed release, reuses `/etc/trop`, runs the target
release's update path, and never reruns setup or regenerates deployment secrets.
See the [worked r65 → r70 upgrade](docs/r65-to-r70.md) for prechecks, exact
commands, validation, and the legacy-layout boundary.

To apply a later edit to the *active* release's configuration:

```bash
sudoedit /etc/trop/zarf-config.yaml
trop config apply
trop health
```

`trop config apply` requires a compatible installed `trop` and active
release. It reapplies configuration without changing `/opt/trop/current`.
Encrypted `/etc/trop/zarf-config.enc.yaml` is also supported when its
SOPS/age key is available. Keep config files and backups root-only; they
contain secrets.

## Checks and recovery

```bash
readlink -f /opt/trop/current      # last activated release
sudo cat /opt/trop/operation-state # last operation/target/step/result on newer releases
trop-doctor health
trop-doctor debug-bundle
```

If a download succeeds but deployment fails, read the resume command printed
by bootstrap. The older `current` link remains on the last healthy release,
but Kubernetes workloads may have changed before a failed health gate; inspect
health before retrying. A retry verifies cached signed packages again. Do not
delete the active release directory. Same-version updates and downgrades are
rejected; upgrade is not a data rollback.

For non-interactive automation, use `--release latest --token-stdin` or
`--list-releases --token-stdin`. Feed the token through standard input from
your secret source, never as an argument or environment variable. `latest`
resolves to an immutable tag before downloading.
