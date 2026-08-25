# TROP Bootstrap

This is a public repository. Never add TROP product source, release packages,
customer configuration, credentials, tokens, internal URLs other than the public
registry endpoint, or copied private documentation.

- Require a TROP Jira key in branches, commits, and pull requests.
- Use pull requests for `main`; never push implementation commits directly.
- Keep the runtime artifact to the single `trop-bootstrap.sh` file.
- Accept secrets only through a hidden prompt or standard input, never arguments.
- Run ShellCheck, the integration tests, and a secret scan before publication.
- Fail closed on malformed credentials, unexpected OCI media types, digest or
  checksum mismatch, unsupported architecture, and missing release assets.
