---
type: Guide
title: AAP monitoring addon
description: Install the optional AAP-focused Prometheus and Grafana monitoring addon.
tags: [monitoring, prometheus, grafana, addons, okf]
status: draft
stale_after: 2027-01-28
resource: https://github.com/RedHatOfficial/aap-demo
---

# AAP monitoring addon

The Python command's optional monitoring addon installs Prometheus, Grafana, and a JSON
adapter that reads AAP controller data through the Gateway API. It is designed for local
customer demonstrations, not production monitoring.

## Use it

Enable monitoring after AAP is ready:

```bash
aap-demo enable monitoring
aap-demo status monitoring
```

Open the Grafana route printed by `status monitoring`. The local Grafana password is stored
in the credential file reported by that command. The password is not printed by status.

The alias below addresses the same Python addon:

```bash
aap-demo enable prometheus
```

Remove the addon and its namespace-owned resources with:

```bash
aap-demo disable monitoring
```

## What is installed

- Prometheus with 24 hours of local retention and a 2 GiB PVC.
- Grafana with the version-controlled AAP Platform Overview dashboard.
- `json-exporter`, which queries the Gateway-proxied controller API using a password mounted
  from an addon-owned Secret and exposes internal Prometheus metrics.
- A Grafana OpenShift Route. Prometheus and the adapter stay cluster-internal.

The first implementation uses static Prometheus scraping because the supported MicroShift
cluster does not provide Prometheus Operator CRDs. ServiceMonitor support remains a future
compatibility-gated extension.

## Troubleshooting

Check the addon resources and logs without printing Secret contents:

```bash
kubectl get pods -n aap-monitoring
kubectl get route grafana -n aap-monitoring
kubectl logs deployment/json-exporter -n aap-monitoring
kubectl logs deployment/prometheus -n aap-monitoring
```

If the adapter reports authorization failures, confirm that AAP is ready and rerun
`aap-demo enable monitoring` so the addon refreshes its copied Gateway credential. If the
dashboard shows no job data, the AAP controller may not have any jobs yet; the initial
population helper is intentionally deferred until its Gateway write contract is validated.
