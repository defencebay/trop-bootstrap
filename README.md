# TROP Bootstrap

`trop-bootstrap.sh` is the public launcher for authenticated TROP Standalone
installation. It contains no TROP product code, customer configuration, registry
credential, or release package.

The launcher uses one per-device token to retrieve private, architecture-specific
installer assets and the signed TROP platform package from Defencebay Harbor. It
downloads a pinned, checksum-verified Zarf client, verifies the signed bootstrap
package and release checksums, and only then offers to run the private installer.

## Download

```bash
curl -fL -o trop-bootstrap.sh \
  https://github.com/defencebay/trop-bootstrap/releases/latest/download/trop-bootstrap.sh
chmod +x trop-bootstrap.sh
```

Review the script, then prepare a release without installing it:

```bash
./trop-bootstrap.sh --release n72-20260825 --fetch-only
```

The script asks for the token with terminal echo disabled. For an approved secret
channel or automation, pass it through standard input:

```bash
secret-tool lookup service trop-bootstrap | \
  ./trop-bootstrap.sh --release n72-20260825 --token-stdin --fetch-only
```

Never put the token in a command argument, URL, shell history, repository, ticket,
or log.

When `--fetch-only` is omitted, the launcher still asks for confirmation before
running `trop-install.sh setup` and again before deploying TROP.

## Requirements

- Linux on `x86_64`/`amd64` or `aarch64`/`arm64`
- Bash 4+
- `curl`, `sha256sum`, `base64`, and standard Unix tools
- outbound HTTPS access to `registry.trop.defencebay.com`
- a valid, project-scoped, pull-only TROP token

## Token format

```text
trop1.<base64url(harbor-robot-username)>.<base64url(harbor-robot-secret)>
```

Base64url is transport encoding, not encryption. The token has the same security
impact as the Harbor robot credential inside it. Tokens are generated only by
the private operator workflow. Use one pull-only Harbor robot per user or device
and disable or delete it to revoke access.

## Trust boundary

This repository intentionally contains only the launcher and its tests. Private
installer assets are stored at:

```text
registry.trop.defencebay.com/trop-releases/<architecture>/trop-bootstrap:<release>
```

Signed platform packages remain at:

```text
oci://registry.trop.defencebay.com/trop-releases/<architecture>/trop-platform:<release>
```

## Development

```bash
shellcheck trop-bootstrap.sh tests/test-bootstrap.sh
./tests/test-bootstrap.sh
```

Changes require a Jira-keyed branch and pull request. Public releases are created
from version tags after tests and a secret scan pass.

## License

Apache-2.0. See [LICENSE](LICENSE).
