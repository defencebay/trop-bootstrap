# TROP Standalone installer

Use this installer on the Ubuntu computer that will run TROP.

You need:

- an internet connection, `curl`, and `sudo` access;
- the release name and TROP token supplied by DefenceBay.

Run:

```bash
mkdir -p ~/trop-bootstrap && cd ~/trop-bootstrap
curl -fL https://github.com/defencebay/trop-bootstrap/releases/latest/download/trop-bootstrap -o trop-bootstrap
chmod +x trop-bootstrap
./trop-bootstrap
```

Follow the prompts and accept the recommended options unless instructed otherwise. Enter the supplied release name and paste the token when requested. The token is hidden and must not be added to the command line.

TROP is installed under `/opt/trop`, while its private configuration is stored under `/etc/trop`. The installer prints the local DNS records required by other devices and does not reboot the computer.

After installation, run `trop` to view status, run health checks, or manage TROP.
