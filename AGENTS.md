# TROP Bootstrap

This is a public repository. Never add TROP product source, release packages,
customer configuration, credentials, tokens, internal URLs other than the public
registry endpoint, or copied private documentation.

- Require a TROP Jira key in branches, commits, and pull requests.
- Use pull requests for `main`; never push implementation commits directly.
- Keep the runtime artifact to the single `trop-bootstrap.sh` file.
- Accept secrets only through a hidden prompt or standard input, never arguments.
- Use the release-pinned Zarf CLI for OCI registry operations; do not add a
  second registry client or implement the distribution protocol here.
- Run ShellCheck, the smoke test, and a secret scan before publication.
- Fail closed on malformed credentials, checksum mismatch, unsupported
  architecture, and missing release assets.
