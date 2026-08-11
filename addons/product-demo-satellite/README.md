# Product Demo - Satellite

Red Hat Satellite integration demonstrations from the
[Ansible Product Demos](https://github.com/ansible/product-demos) collection.

## What it Creates

Job templates for Satellite automation scenarios:

- **SATELLITE | Publish Content View Version** — publish content views
- **SATELLITE | Promote Content View Version** — promote through lifecycle environments
- **LINUX | Register with Satellite** — register systems to Satellite
- **LINUX | Compliance Scan with Satellite** — OpenSCAP compliance scanning
- **SETUP | Satellite** — bootstrap content views, lifecycle environments, and activation keys
- **Patch Dev** — workflow tying inventory sync, publishing, and patching together

Upstream ships placeholder Satellite credentials (`https://satellite.example.com`, username
`REPLACEME`). Domain install creates the templates; **SETUP | Satellite** only succeeds after you
point credentials at a real server.

## Usage

```bash
# Install Satellite demos (also installs base if needed)
aap-demo enable product-demo-satellite

# Remove Satellite demos
aap-demo disable product-demo-satellite
```

When installing all domains at once, Satellite is excluded by default. Add it when you have a server:

```bash
PRODUCT_DEMOS_DOMAINS="linux windows network cloud openshift satellite" aap-demo enable product-demos
```

Or install Satellite separately:

```bash
aap-demo enable product-demo-satellite
```

## Prerequisites

- AAP deployed via `aap-demo deploy`
- Product demos base addon (installed automatically)
- A reachable **Red Hat Satellite** (or Foreman) server with API access
- Subscription manifest imported on Satellite (required for `SETUP | Satellite`)

## Updating Satellite credentials

After install, update **both** credentials in the **Ansible Product Demos (APD)** organization.
They start with upstream placeholders and must match your environment before setup or demo jobs
will run.

### AAP UI

1. Log into AAP and open **Ansible Product Demos (APD)** → **Credentials**.
2. Edit **Satellite Credential** (type **Satellite Collection**):
   - **Satellite Hostname** — base URL, e.g. `https://satellite.example.com`
   - **Satellite Username** — API user (often `admin` or a dedicated service account)
   - **Satellite Password** — password or API token for that user
3. Edit **Satellite Inventory** (type **Red Hat Satellite 6**):
   - **Host** — same Satellite URL as above
   - **Username** / **Password** — same API credentials (used for dynamic inventory sync)
4. Save both credentials.

The **Satellite Collection** credential type injects `SATELLITE_SERVER`, `SATELLITE_USERNAME`,
and `SATELLITE_PASSWORD` into job pods. Demo playbooks use those environment variables to call
the Satellite API.

### Controller API (optional)

Look up credential IDs, then patch inputs:

```bash
NAMESPACE=aap-operator
AAP_ROUTE=$(kubectl get route aap -n "$NAMESPACE" -o jsonpath='{.spec.host}')
AAP_PASSWORD=$(kubectl get secret aap-admin-password -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)
AAP_API="https://${AAP_ROUTE}/api/controller/v2"

# Find Satellite Credential in the APD org
CRED_ID=$(curl -sk -u "admin:${AAP_PASSWORD}" \
  "${AAP_API}/credentials/?name=Satellite+Credential&organization=2" \
  | jq -r '.results[0].id')

curl -sk -u "admin:${AAP_PASSWORD}" \
  -X PATCH \
  -H "Content-Type: application/json" \
  -d '{
    "inputs": {
      "host": "https://satellite.example.com",
      "username": "admin",
      "password": "REPLACEME"  # pragma: allowlist secret
    }
  }' \
  "${AAP_API}/credentials/${CRED_ID}/"
```

Repeat for **Satellite Inventory** (same `inputs` shape; type is **Red Hat Satellite 6**).

## Re-run Satellite setup

Domain install (`setup_demo.yml` with `demo=satellite`) creates job templates and then launches
**SETUP | Satellite** automatically. That job fails until credentials point at a real server —
the demo templates are still created.

After updating credentials:

1. **Templates** → **SETUP | Satellite** → **Launch**.
2. Wait for the job to finish. It creates RHEL7/RHEL8 content views, lifecycle environments
   (Dev/QA/Prod), activation keys, and SCAP tailoring files on Satellite.
3. **Inventories** → **Ansible Product Demos Inventory** → **Sources** → **Satellite Inventory**
   → **Sync** (or run the **Satellite Inventory** job template for the Patch Dev workflow).

Then run demo templates such as **SATELLITE | Publish Content View Version** or
**LINUX | Register with Satellite**.

### Re-run only the Satellite domain install

If Satellite failed during bulk install, re-launch **APD | Install Satellite Demos** from
**Templates** in the **Default** organization (after updating credentials).

Prefer launching **SETUP | Satellite** directly if demo templates already exist.

## Troubleshooting

| Symptom | Likely cause | Fix |
| -------- | ------------- | ----- |
| `Failed to connect to Foreman server` / `satellite.example.com` | Placeholder credentials not updated | Update **Satellite Credential** and **Satellite Inventory**, then re-run **SETUP \| Satellite** |
| `SETUP \| Satellite` failed but `SATELLITE \| *` templates exist | Expected without a real Satellite during bulk install | Update credentials and run **SETUP \| Satellite** manually |
| Inventory sync empty or errors | **Satellite Inventory** credential wrong or Satellite unreachable from job pods | Verify URL, credentials, and network from the cluster to Satellite |
| Manifest / subscription errors during setup | No manifest on Satellite | Import a subscription manifest in Satellite before running setup |

## Resources

- [Product Demos — Satellite (upstream setup.yml)](https://github.com/ansible/product-demos/blob/main/satellite/setup.yml)
- [Product Demos Repository](https://github.com/ansible/product-demos)
