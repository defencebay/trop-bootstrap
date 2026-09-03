# TROP Standalone installer

Use this installer on the Ubuntu computer that will run TROP.

You need:

- an internet connection, `curl`, and `sudo` access;
- a TROP token supplied by DefenceBay.

Run:

```bash
mkdir -p ~/trop-bootstrap && cd ~/trop-bootstrap
curl -fL https://github.com/defencebay/trop-bootstrap/releases/latest/download/trop-bootstrap -o trop-bootstrap
chmod +x trop-bootstrap
./trop-bootstrap
```

Follow the prompts and accept the recommended options unless instructed otherwise. Paste the token when requested. The installer lists complete stable releases available to that token and recommends the latest one. The token is hidden and must not be added to the command line.

Before deployment, the guided installer asks separately for explicit `true` or
`false` consent for every optional integration with the Ubuntu host:

- `MANAGE_LOCAL_HOSTS` controls only the marked TROP block in `/etc/hosts`;
- `INSTALL_HOST_CA` controls installation of the TROP CA in the system trust
  store;
- `INSTALL_OPERATOR_TOOLS` controls `/usr/local/bin/trop`,
  `/usr/local/bin/trop-doctor`, `/usr/local/bin/trop-install`,
  `/usr/local/lib/trop-doctor`, and `/etc/trop/doctor.conf`.

Choosing `false` means deploy, update, and normal uninstall do not create,
replace, or remove that integration. Missing flags in an older imported config
are treated as `false`; there is no implicit opt-in. The installer prints the
effective flags before deployment. Required deploy effects are shown separately:
TROP workloads and persistent application data are installed or updated, and
the bundled k3s/Zarf stack is initialized only when no ready installation exists.
The managed `/opt/trop/current` pointer changes only after health validation.

At the start of the interactive wizard, the launcher also checks whether a newer
public `trop-bootstrap` version is available. A failed network check never blocks
installation. When an update exists, it prints a safe command that downloads the
new launcher to `trop-bootstrap.new`; it never replaces or executes the current
script automatically. Non-interactive automation does not perform this check.

For automation, resolve the newest stable release with `--release latest --token-stdin`. Use `--list-releases --token-stdin` to print the stable releases available for the current computer architecture. The token must be provided on standard input, never as an argument or environment variable. `latest` is resolved to an immutable release tag before any package is downloaded.

With the recommended destination, verified immutable release assets are stored
under `/opt/trop/releases/<release>`, `/opt/trop/current` points to the last
healthy deployed release, and private configuration is stored under `/etc/trop`.
Each release directory is a persistent, complete bundle containing the installer,
Zarf tools, signed application package, and checksums. It is not a temporary
download directory and does not contain k3s workload data. The active bundle
supplies management and safe-uninstall tools and must remain intact.

An upgrade creates a new versioned directory and changes `/opt/trop/current` only
after its health check succeeds. Older release directories are retained; the
current launcher does not remove them automatically. A custom `--dest` is an
operator-owned download/checkpoint directory; it keeps the assets and local
config there and does not participate in the managed `/opt/trop/current` layout.
The installer prints the local DNS records required by other devices and does
not reboot the computer.

After installation, run `trop` to view status, run health checks, or manage TROP.

Running the bootstrap again on a healthy system detects the active release and uses the installer update path. It reuses the root-only configuration in `/etc/trop`, rejects same-version and downgrade attempts, and advances `/opt/trop/current` only after the update health gate succeeds. This is not a data rollback mechanism.
