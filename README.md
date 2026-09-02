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

At the start of the interactive wizard, the launcher also checks whether a newer
public `trop-bootstrap` version is available. A failed network check never blocks
installation. When an update exists, it prints a safe command that downloads the
new launcher to `trop-bootstrap.new`; it never replaces or executes the current
script automatically. Non-interactive automation does not perform this check.

For automation, resolve the newest stable release with `--release latest --token-stdin`. Use `--list-releases --token-stdin` to print the stable releases available for the current computer architecture. The token must be provided on standard input, never as an argument or environment variable. `latest` is resolved to an immutable release tag before any package is downloaded.

With the recommended destination, verified immutable release assets are stored
under `/opt/trop/releases/<release>`, `/opt/trop/current` points to the last
healthy deployed release, and private configuration is stored under `/etc/trop`.
This destination is an artifact/release directory, not the k3s workload-data
directory. A custom `--dest` is an operator-owned download/checkpoint directory;
it keeps the assets and local config there and does not participate in the
managed `/opt/trop/current` layout. The installer prints the local DNS records
required by other devices and does not reboot the computer.

After installation, run `trop` to view status, run health checks, or manage TROP.

Running the bootstrap again on a healthy system detects the active release and uses the installer update path. It reuses the root-only configuration in `/etc/trop`, rejects same-version and downgrade attempts, and advances `/opt/trop/current` only after the update health gate succeeds. This is not a data rollback mechanism.
