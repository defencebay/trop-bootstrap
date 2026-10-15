# Change CPU and memory per service

This feature requires a signed private installer/platform release containing
per-service resource support. Packages r81 and older do not implement it. A new public launcher alone cannot add resource
mappings to an older immutable package. Check the selected release notes before
using these instructions.

## Edit and apply

After setup, keep installation-specific requests and limits in
`/etc/trop/resources.yaml`. New setup with a supporting release creates an empty
file. On an upgraded installation, create it if needed:

```bash
sudoedit /etc/trop/resources.yaml
```

For example, increase PostgreSQL and enrollment memory, and adjust TOC BFF CPU:

```yaml
resources:
  postgres:
    requests:
      memory: 1Gi
    limits:
      memory: 2Gi
  eud-handler-ssl:
    limits:
      memory: 2Gi
  enrollment-ssl:
    limits:
      memory: 512Mi
  trop-toc-bff:
    requests:
      cpu: 100m
    limits:
      cpu: 1
      memory: 768Mi
```

These are example overrides, not minimum requirements. Set only the fields that
need changing. Each service accepts `requests.cpu`, `requests.memory`,
`limits.cpu` and `limits.memory`. Unspecified fields retain the release defaults.
CPU `250m` means one quarter of a core; `1` means one core. RAM examples are
`512Mi` and `2Gi`. Requests reserve scheduler capacity; limits cap container use.
Requests must not exceed limits, and the host must have enough capacity.

```bash
trop config apply
trop health
```

Without the optional global tools, use the active verified installer:

```bash
sudo /opt/trop/current/trop-install.sh config-apply
```

Applying resource changes rolls affected pods and may briefly interrupt
connections. The installer reads the same file for installation, config apply
and upgrades; no manual patch or post-upgrade reapply is needed. Keep it alongside
`/etc/trop/zarf-config.yaml`, not inside a release directory. For an installation
previously changed with `kubectl`, record the desired settings here before its
first upgrade to a supporting release. Existing secrets and data volumes remain.

## Service keys

Use these exact keys below `resources:`. Each key configures one workload or
container, including sidecars in a shared pod. Settings do not enable an optional
component; its existing profile/configuration must enable it first.

| Component | Service keys |
| --- | --- |
| Infrastructure | `postgres`, `rabbitmq`, `postgres-exporter` |
| Server | `trop-server`, `cot-parser`, `trop-server-ui`, `eud-handler`, `eud-handler-ssl`, `enrollment-ssl`, `raven-ingest`, `colata-ingest`, `peat-gateway`, `peat-mesh` |
| Ingress and XMPP | `traefik`, `ejabberd` |
| Cloud and media | `trop-cloud-api`, `trop-cloud-events`, `trop-cloud-tiles`, `trop-cloud-postgis`, `trop-cloud-vaults3`, `trop-cloud-postgres-exporter`, `trop-cloud-media` |
| TOC | `trop-toc-web`, `trop-toc-bff`, `trop-toc-valkey` |
| Crisis | `trop-crisis-management-backend`, `trop-crisis-management-frontend`, `trop-crisis-management-n8n`, `trop-crisis-management-tile38`, `trop-crisis-management-migration` |
| Optional services | `streams-ai`, `img-to-markers`, `trop-id`, `external-observability` |

The package schema rejects unknown service names, unsupported fields and malformed
quantities before deployment. The file only controls CPU/RAM: image, replicas,
storage, credentials and feature flags do not belong here. Kubernetes enforces
request/limit consistency. To restore a packaged default, remove the relevant
field (or the service entry) and apply again; `resources: {}` restores all
packaged resource defaults.

## Verify after applying or upgrading

Check the resulting resource declarations, readiness and current usage:

```bash
sudo k3s kubectl -n zarf-trop get pods
sudo k3s kubectl -n zarf-trop get deployment trop-server -o yaml
sudo k3s kubectl -n zarf-trop get statefulset postgres -o yaml
sudo k3s kubectl -n zarf-trop top pods --containers
```

In the workload YAML, inspect `spec.template.spec.containers[].resources`.
`top` needs a working Metrics API and reports current usage, not configured
requests/limits. After a normal upgrade, verify the same declarations and run
`trop health` again. A pod stuck Pending can indicate insufficient requested
capacity; an OOMKilled restart can indicate a memory limit below actual usage.
