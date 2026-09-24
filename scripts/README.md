# Bootstrap checks

Run locally with Zarf v0.70.1, Cosign, Python 3, Bash, and ShellCheck installed:

```bash
bash -n trop-bootstrap.sh
shellcheck trop-bootstrap.sh
python3 scripts/test-bootstrap.py -v
```

The test suite generates a fresh Cosign key pair in a private temporary
directory, builds small signed Zarf packages, and deletes all fixture keys and
packages afterward. It does not contact a registry or a Kubernetes cluster.
