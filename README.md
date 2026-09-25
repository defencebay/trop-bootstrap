# TROP Standalone: operator walkthrough

Run these commands **on the Ubuntu computer that will run TROP**. You need `curl`, `sudo`, internet access for the connected path, and a TROP token from DefenceBay. These GIFs show **illustrative terminal sessions**, not a live deployment. Copy commands from the code blocks.

## 1. Install and set up a new host

![Illustrative installation and setup terminal session](docs/media/install.gif)

Download the public launcher into any convenient working directory. We use `~/trop-bootstrap`. That directory holds only the launcher; the wizard installs verified bundles under `/opt/trop/releases/<release>` by default.

```bash
mkdir -p "$HOME/trop-bootstrap" && cd "$HOME/trop-bootstrap"
curl -fL https://github.com/defencebay/trop-bootstrap/releases/latest/download/trop-bootstrap \
  -o trop-bootstrap
chmod +x trop-bootstrap
./trop-bootstrap
```

The token prompt hides what you type. Press Enter for the latest complete stable release and the recommended destination. Choose **1** to download, verify, configure, and install. Here is a sample Platform + TOC setup:

```text
TROP token: [hidden input]
TROP release tag [<latest stable release>]: [Enter]
Verified release-assets directory [/opt/trop/releases/<release>]: [Enter]
Choose an option [1]: 1
Continue? [Y/n]: y

Installation profile: 3             # Platform + TOC
Setup mode: 1                       # Standard
TROP Server hostname: trop.example.com
LAN address for TROP: 192.168.20.10 # client-facing interface
```

The setup wizard then asks for the administrator password at a hidden prompt, how this host resolves TROP names, and separate consent for the host CA and global operator commands. Review its plan before deploying. Enable **operator tools** to use the commands below. Other LAN devices still need DNS or hosts records for the TROP names; this host's `/etc/hosts` choice does not configure them.

Check the result:

```bash
readlink -f /opt/trop/current
trop status
trop health
trop-doctor install-validate
```

`install-validate` prompts for administrator credentials. The successful release is linked at `/opt/trop/current`; private configuration lives in `/etc/trop`, while application data is managed separately by k3s.

## 2. Upgrade an installed host

![Illustrative guided upgrade terminal session](docs/media/upgrade.gif)

```bash
trop health
trop upgrade
readlink -f /opt/trop/current
trop health
```

The guided upgrade downloads the current public launcher, asks for the token, offers complete stable releases, and shows the target before installing. It reuses `/etc/trop`; **do not run setup again**. Keep the recommended destination. The health gate moves `/opt/trop/current` to the new release; previous bundles remain on disk.

If the installed `trop` is too old for `trop upgrade`, refresh the launcher with the commands in step 1 and run `./trop-bootstrap` on the installed host. It detects the managed installation and takes its update path. For a specific version, use `./trop-bootstrap --release <release>`; a newer operator CLI may also support `trop upgrade --release <release>`. Use an exact tag offered for your architecture, such as `rNN-YYYYMMDD`.

## 3. Change the active release's configuration

![Illustrative configuration apply terminal session](docs/media/config-apply.gif)

Edit the existing root-only config and apply it. This redeploys affected workloads without switching releases or requiring a separate restart.

```bash
sudoedit /etc/trop/zarf-config.yaml
trop config apply
trop health
```

For example, to enable GlitchTip **after upgrading to a release that supports it**, add these keys under the existing `package.deploy.set` mapping. Use the actual DSNs issued for each service project; the values here are placeholders.

```yaml
package:
  deploy:
    set:
      ENABLE_GLITCHTIP: "true"
      SENTRY_ENVIRONMENT: "your-environment"
      TROP_SERVER_SENTRY_DSN: "<server project DSN>"
      TROP_SERVER_UI_SENTRY_DSN: "<server UI project DSN>"
      TROP_CLOUD_SENTRY_DSN: "<cloud project DSN>"
      TROP_TOC_SENTRY_DSN: "<TOC project DSN>"
```

Keep the existing mapping and other settings intact. If your host uses SOPS-encrypted `/etc/trop/zarf-config.enc.yaml`, edit the protected source using your site's key workflow; do not create a shared plaintext copy.

## 4. Restart TROP when needed

![Illustrative TROP restart terminal session](docs/media/restart.gif)

```bash
trop restart-all
trop health
```

`restart-all` restarts local k3s and waits for TROP workloads. For a full computer reboot, use `sudo reboot` instead. A successful upgrade or `trop config apply` already performs its own rollout.

## Where things live and which command to use

| Path or command | Meaning |
| --- | --- |
| `~/trop-bootstrap/trop-bootstrap` | Example location of the public launcher; it can be elsewhere |
| `/opt/trop/releases/<release>` | Persistent verified bundle: installer, Zarf tools, signed packages, checksums |
| `/opt/trop/current` | Symlink to the last release that passed the health gate |
| `/etc/trop/zarf-config.yaml` | Root-only deployment configuration; some hosts use its encrypted form |
| `trop` | Operator menu, health, upgrade, config apply, restart, when operator tools are enabled |
| `trop-doctor` | Detailed validation and diagnostics behind the operator CLI |
| `trop-install` | Lower-level, release-local deploy/update and recovery commands |

Running the launcher from `~/trop-bootstrap` does **not** install TROP under your home directory. `--dest` changes the download/checkpoint directory for one bundle; it does **not** relocate a managed installation. See the [custom-directory recipe](docs/operator-examples.md#download-a-verified-bundle-to-a-custom-directory).

## Debug and recovery

```bash
trop status
trop health
trop-doctor failing-pods
trop-doctor debug-bundle
sudo cat /opt/trop/operation-state
```

On newer releases, operation state records the last operation and step. If deployment fails after download, inspect health and use the resume command printed by the launcher. The old `current` link remains on the last healthy release, although workloads may have changed before a failed health gate. A retry re-verifies retained signed assets. Never delete the active release directory. An upgrade is not a data rollback.

## Advanced configuration and manual paths

The [advanced operator recipes](docs/operator-examples.md) cover a download checkpoint, a custom directory, a manual first deploy, and older operator tools. For automation, bootstrap accepts `--release latest --token-stdin` or `--list-releases --token-stdin`. Feed a token through standard input from your secret source, never as a shell argument or environment variable. `latest` resolves to an immutable tag before download.

The example animations are generated by [`scripts/render-terminal-demos.py`](scripts/render-terminal-demos.py). Install Pillow and run `python3 scripts/render-terminal-demos.py` to regenerate them.
