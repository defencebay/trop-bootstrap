# Bootstrap checks

Run locally with Zarf v0.70.1, Cosign, Python 3, Bash, and ShellCheck installed:

```bash
python3 scripts/build-launchers.py --check
bash -n trop-bootstrap.sh
bash -n trop-bootstrap-go.sh
shellcheck trop-bootstrap.sh trop-bootstrap-go.sh
python3 scripts/test-bootstrap.py -v
```

The test suite generates a fresh Cosign key pair in a private temporary
directory, builds small signed Zarf packages, and deletes all fixture keys and
packages afterward. It does not contact a registry or a Kubernetes cluster.

## Maintaining and packaging the launchers

Maintain shared behavior in `trop-bootstrap.sh`. Run
`python3 scripts/build-launchers.py` after changes to regenerate the standalone
Go file. Only the fixed backend and launcher asset name differ; CI fails if the
committed Go file drifts from its source. Both files work independently after
renaming and need no sibling source file or extra code download at runtime.

When preparing a public release, publish `trop-bootstrap.sh` as `trop-bootstrap`
and `trop-bootstrap-go.sh` as `trop-bootstrap-go` from the same checked revision.
Publishing these assets does not publish or qualify a private Go application release.
