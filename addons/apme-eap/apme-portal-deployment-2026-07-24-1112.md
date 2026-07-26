# Ansible Quality (APME) automation portal deployment

Deployment date: 2026-07-24T16:12:43Z

## Portal access

- **Portal URL:** https://redhat-rhaap-portal-apme.apps.127.0.0.1.nip.io
- **OpenShift namespace:** apme
- **Cluster domain:** apps.127.0.0.1.nip.io

## AAP integration

- **AAP host:** https://aap-aap-operator.apps.127.0.0.1.nip.io
- **Organization:** Default
- **OAuth application:** APME Portal OAuth
- **Redirect URI:** https://redhat-rhaap-portal-apme.apps.127.0.0.1.nip.io/api/auth/rhaap/handler/frame
- **GitHub OAuth callback:** https://redhat-rhaap-portal-apme.apps.127.0.0.1.nip.io/api/auth/github/handler/frame (optional: confirm on github.com)

## APME plugins

- **Plugin SHA:** 8593383
- **OCI registry:** registry.apps.127.0.0.1.nip.io/apme
- **Image:** `registry.apps.127.0.0.1.nip.io/apme/apme-prototype-plugins:8593383`

## Helm releases

| Release | Chart | Version |
| --- | --- | --- |
| redhat-rhaap-portal | redhat-rhaap-portal | 2.2.3 |
| apme | apme | 0.1.2 |

## Verification

```bash
oc get pods -n apme
oc get route -n apme
oc get secret secrets-rhaap-portal -n apme
```

## Next steps

1. Sign in to the automation portal via AAP OAuth.
2. Register a repository (public repos support direct register).
3. Open the **Quality** tab and run a scan on the default branch.
