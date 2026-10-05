# TROP Standalone

Run on the Ubuntu host. Required: `curl`, `sudo`, internet access and a DefenceBay TROP token. Choose a [profile and host size](docs/requirements.md) first.

## Fresh install

![Install and setup terminal demo](docs/media/install.gif)

```bash
mkdir -p "$HOME/trop-bootstrap" && cd "$HOME/trop-bootstrap"
curl -fL https://github.com/defencebay/trop-bootstrap/releases/latest/download/trop-bootstrap -o trop-bootstrap
chmod +x trop-bootstrap
./trop-bootstrap
```

```text
TROP token: [hidden input]
TROP release tag [latest stable]: [Enter]
Verified release-assets directory [/opt/trop/releases/<release>]: [Enter]
Choose an option [1]: 1
Installation profile: 3             # 1 Server; 2 Platform; 3 Platform + TOC
Setup mode: 1                       # Standard
TROP Server hostname: trop.example.com
LAN address for TROP: 192.168.20.10 # client-facing interface
Install global TROP operator tools on this server? true
```

```bash
readlink -f /opt/trop/current
trop status
trop health
trop-doctor install-validate
```

The wizard asks for host integrations separately; review its plan. `install-validate` prompts for administrator credentials. Configure DNS for other LAN clients separately.

```text
./trop-bootstrap                        public launcher, before install
/opt/trop/releases/<release>/           verified bundle after download
/etc/trop/zarf-config.yaml              private config after setup
/usr/local/bin/trop, trop-doctor        during deploy if INSTALL_OPERATOR_TOOLS=true
/opt/trop/current, trop-install         after a successful health gate
```

`trop` is optional, never a bootstrap prerequisite. Its presence during deploy does not prove the final health gate passed. On an older host, check `trop --help` and `trop-doctor version`; r70 bundles doctor 0.4.5 with `--release` and `config apply`.

## Upgrade

![Upgrade terminal demo](docs/media/upgrade.gif)

```bash
trop health
trop upgrade
readlink -f /opt/trop/current
trop health
```

The guided command fetches the launcher, prompts for the token and lists stable releases. It reuses `/etc/trop`. For an older helper, download `./trop-bootstrap` as above and run it on the installed host. For a specific tag: `./trop-bootstrap --release rNN-YYYYMMDD` or, on a newer helper, `trop upgrade --release rNN-YYYYMMDD`.

## Apply config

![Config apply terminal demo](docs/media/config-apply.gif)

```bash
sudoedit /etc/trop/zarf-config.yaml
trop config apply
trop health
```

For SOPS installations, edit `/etc/trop/zarf-config.enc.yaml` with the site's key workflow. `config apply` performs the rollout.

## Restart

![Restart terminal demo](docs/media/restart.gif)

```bash
trop restart-all
trop health
```

`restart-all` restarts local k3s and waits for workloads. For a host reboot: `sudo reboot`.

## Debug and advanced

```bash
trop status
trop health
trop-doctor failing-pods
trop-doctor debug-bundle
sudo cat /opt/trop/operation-state
```

[Operator examples](docs/operator-examples.md) has manual deploy, resume, automation and custom `--dest` commands. The default managed bundle path is `/opt/trop/releases/<release>`; `/opt/trop/current` selects the healthy release. A custom `--dest` is a download/checkpoint directory, not a relocation of the managed install. Application data lives in k3s volumes. Keep the active bundle; upgrades are not data rollbacks.

Animations are illustrative. Regenerate with `python3 scripts/render-terminal-demos.py` after installing Pillow.

## Optional external log collection

The signed platform release includes `external-observability` and a pinned Alloy
image for its architecture. Bootstrap fetches and verifies the complete platform
package as usual; the component requires no separate download or bootstrap flag.

The private installer asks for explicit consent to send TROP namespace logs to a
central HTTPS endpoint. This defaults to **false** in every installation profile
and when importing a configuration that has no observability flag. Opt-in needs
an installation ID, an approved `/loki/api/v1/push` URL, and an existing
namespace-local Secret with `username` and `password`. Credentials are not part
of the public bootstrap token or the installer review.

For a fresh host, install with the default disabled state first, provision the
Secret, then set these keys under `package.deploy.set` in the protected deployment
configuration and run `trop config apply`. Use the installation ID and endpoint
provided by your operator; the values below are placeholders:

```yaml
ENABLE_EXTERNAL_OBSERVABILITY: "true"
EXTERNAL_OBSERVABILITY_INSTALLATION_ID: "installation-id"
EXTERNAL_OBSERVABILITY_LOKI_ENDPOINT: "https://logs.example.com/loki/api/v1/push"
EXTERNAL_OBSERVABILITY_CREDENTIALS_SECRET: "external-observability-credentials"
```

Normal verified upgrades preserve the choice. Set the flag to `false` and apply
the config to remove the collector. Doctor v0.5.0 adds `trop observability status`
which checks local Alloy health and log-send counters over 10 seconds without
reading credentials or creating pods. `trop observability test` is an alias.
No new sends may simply mean applications are quiet. The tools version is pinned
by the private platform release, so fetching an older release does not add this
feature.
