# Standalone host and component requirements

Use this alongside the [operator walkthrough](../README.md). The figures below describe the signed `r70-20260924` platform package's **default Zarf chart values**. They are Kubernetes requests and PersistentVolumeClaim (PVC) sizes, **not tested minimum host specifications**.

## Before downloading

- Use an Ubuntu host with `systemd`, `sudo`, `bash`, `curl`, and `openssl`. The launcher accepts Linux `amd64` (x86_64) and `arm64` (aarch64); use the release built for the host architecture. The isolated install and upgrade qualification used Ubuntu on amd64.
- Provide a client-facing LAN IPv4 address. The chosen Server, Cloud, XMPP, and TOC names must resolve to it wherever clients will connect. The wizard can manage a marked `/etc/hosts` block on this host, but cannot configure other devices or their DNS.
- For a connected download, allow HTTPS to GitHub and the private TROP release registry and have a pull-scoped TROP token. The bundle includes the pinned Zarf runtime and k3s init package; `trop`, `trop-doctor`, Docker, and a preinstalled k3s cluster are not first-install prerequisites.
- Plan local SSD space for **both** the complete signed release archive under `/opt/trop/releases/<release>` and the unpacked k3s images/PVC data under `/var/lib/rancher/k3s`. Upgrades retain older release bundles. A default StorageClass is needed for the chart PVCs; the bundled single-node k3s init supplies one.

A quick host inventory before running the launcher:

```bash
uname -m
nproc
free -h
df -h /opt /var
command -v curl openssl systemctl sudo
```

## What each installation profile deploys

| Wizard selection | Deployed from the complete package | Steady pod CPU requests | Steady pod memory requests | Default PVC claims |
| --- | --- | ---: | ---: | ---: |
| `1` Server only | Infra, Traefik, Server/UI, Media, ejabberd | 1,200m | 3,904 MiB | 39 GiB |
| `2` Platform (default) | Server-only set + Cloud | 1,700m | 5,312 MiB | 70 GiB |
| `3` Platform + TOC | Platform set + TOC web/BFF/Valkey | 1,825m | 5,568 MiB | 71 GiB |

The installer excludes Cloud and TOC when the profile disables them. Media and ejabberd remain part of **all three** profiles. TOC requires Cloud. A migration Job and Zarf/k3s system processes are excluded from the steady pod totals; deployment briefly needs more capacity.

These are the parts behind the totals:

| Zarf component | What it starts | CPU requests | Memory requests | Default PVC claims |
| --- | --- | ---: | ---: | ---: |
| Infra | PostgreSQL, RabbitMQ; TROP data and recording claims | 300m | 1,024 MiB | 37 GiB |
| Traefik | Local ingress and protocol routes | 100m | 128 MiB | — |
| Server | Backend, CoT parser, web UI, server sidecars | 600m | 2,240 MiB | — |
| Media | MediaMTX/gateway; uses infra recording claim | 100m | 256 MiB | — |
| ejabberd | XMPP | 100m | 256 MiB | 2 GiB |
| Cloud (optional) | API, events, tiles, MinIO, PostGIS, VaultS3 | 500m | 1,408 MiB | 31 GiB |
| TOC (optional) | Web, BFF, Valkey | 125m | 256 MiB | 1 GiB |

The PVC figures are **logical claims**, not disk reserved in advance by the default local-path provisioner. Recording retention, database growth, image layers, the release archive, and a second retained bundle all consume additional disk. Kubernetes requests are scheduler reservations, not expected peak RAM/CPU use; do not size the host by adding only the request column.

## Example host sizes for planning

| Profile | Starting example | Why this has headroom |
| --- | --- | --- |
| Server only | 2–4 vCPU, 8 GiB RAM, 100 GiB SSD | Above the 3.8 GiB pod request; leaves room for k3s, images, a retained bundle, and moderate data growth. |
| Platform or Platform + TOC | 4 vCPU, 16 GiB RAM, 150 GiB SSD | Above the roughly 5.2–5.4 GiB pod request and 70–71 GiB logical PVC claims; leaves room for runtime and upgrades. |

These are **conservative starting examples**, not supported minimums or a throughput guarantee. The repository's disposable EC2 test fixture uses 4 vCPU, 16 GiB RAM, and a 50 GB root disk; that 50 GB is a test fixture with mostly empty claims, not a production disk recommendation. Increase CPU/RAM for many concurrent clients, video processing, or extra integrations; increase storage for recordings and for how many old releases you keep.

## The downloaded bundle is always complete

`--fetch-only` and Server-only setup still fetch the signed platform package containing Cloud and TOC images. Profile selection changes which components are **deployed**, not the signed archive size. The exact bytes depend on the release and architecture; there is no single fixed download-size requirement. After fetching, inspect the actual archive and free space before deploying:

```bash
du -sh /opt/trop/releases/*
ls -lh /opt/trop/releases/<release>/*.tar.zst
df -h /opt /var
```

Replace `<release>` with the selected tag. Do not delete the active directory reported by `readlink -f /opt/trop/current`. On a first installation, `trop-doctor install-preflight` is **not available yet**; it arrives only if the operator-tools option is enabled during deployment.

These numbers come from rendering the [r70 Zarf platform manifest](https://github.com/defencebay/trop-infra/blob/r70-20260924/zarf/packages/platform/zarf.yaml) with each component's `values-zarf.yaml` and chart defaults in [trop-infra](https://github.com/defencebay/trop-infra/tree/r70-20260924/helm/charts/trop). Recalculate them for a newer release or changed chart values.
