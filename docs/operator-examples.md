# Operator examples: setup and custom paths

All commands here run **on the Ubuntu TROP host**. The public
`trop-bootstrap` launcher may be downloaded into any working directory.
Its recommended managed destination is always
`/opt/trop/releases/<release>`, with private config in `/etc/trop`.

## Example A: fresh Platform + TOC installation

Suppose your host has client-facing LAN address `192.168.20.10` and DNS names
`trop.example.com`, `trop-web.example.com`, and
`trop-toc.example.com`. First make those names resolve to the host for
clients. Then run:

```bash
mkdir -p "$HOME/trop-bootstrap" && cd "$HOME/trop-bootstrap"
curl -fL https://github.com/defencebay/trop-bootstrap/releases/latest/download/trop-bootstrap \
  -o trop-bootstrap
chmod +x trop-bootstrap
./trop-bootstrap
```

At the prompts, use the real token at the hidden prompt, select the latest
complete stable release and the recommended
`/opt/trop/releases/<release>` destination, then choose to configure and
install. A typical setup answer set is:

| Prompt | Example answer | Effect |
| --- | --- | --- |
| Installation profile | `3` — Platform + TOC | Server, Cloud, and TOC |
| Setup mode | `1` — Standard | Derive Cloud, XMPP, and TOC names from the Server name |
| TROP Server hostname | `trop.example.com` | Derives `trop-web.example.com` and `trop-toc.example.com` |
| LAN address | Select `192.168.20.10` from detected addresses | TROP listens on the client-facing address |
| Host name resolution | `1` if DNS is not ready on this host | Add only the marked TROP block to this host's `/etc/hosts` |
| Administrator password | Enter twice at the hidden prompts | Stored in root-only deployment config |
| Host CA | `Y` for automatic TROP CA | Trust the CA on the Ubuntu host |
| Operator tools | `Y` | Install `trop`, `trop-doctor`, `trop-install` |
| Write configuration | `Y` after reviewing the plan | Save `/etc/trop/zarf-config.yaml` and generate secrets |

The `/etc/hosts` choice changes **only this Ubuntu host**. Phones and other
LAN clients still need DNS or hosts records for the same names. If you already
have working DNS on the host, choose `2` and leave `/etc/hosts` untouched.
If you do not want the global operator commands, answer `n`; the release
remains available under `/opt/trop/current`.

When deployment finishes:

```bash
readlink -f /opt/trop/current
trop status
trop health
trop-doctor install-validate
```

## Example B: download to a custom directory

Use this if you need to inspect or transfer a **verified bundle** before
installing it:

```bash
mkdir -p "$HOME/trop-bundles"
./trop-bootstrap --release r70-20260924 \
  --dest "$HOME/trop-bundles/r70-20260924" --fetch-only
cd "$HOME/trop-bundles/r70-20260924"
ls trop-install.sh SHA256SUMS-* zarf-package-trop-platform-*.tar.zst
```

This does not deploy anything. `--dest` is not a relocation flag for the
managed installation. If you later run this bundle's `./trop-install.sh setup`
and `deploy` in that custom directory, its config stays local and it will
not create `/opt/trop/current`. You own the directory, its config protection,
and the next manual update. Use the recommended managed destination when you
want `trop upgrade` and `trop config apply`.

For an existing managed installation, this is the correct release checkpoint:

```bash
./trop-bootstrap --release r70-20260924 --fetch-only
cd /opt/trop/releases/r70-20260924
sudo ./trop-install.sh update zarf-package-trop-platform-amd64-r70-20260924.tar.zst
```

That `update` reuses `/etc/trop`. Do not run `setup` again on an installed
host. The example package is amd64; use the architecture-specific name printed
by bootstrap on another host.

## Example C: edit configuration after installation

```bash
sudoedit /etc/trop/zarf-config.yaml
trop config apply
trop health
readlink -f /opt/trop/current
```

The last command should still point to the same release. If your config is
SOPS-encrypted, edit the protected source appropriately; do not create an
unprotected plaintext copy in a shared directory. `trop config apply` uses
the existing encrypted config and its available key.
