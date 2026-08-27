<!-- markdownlint-disable MD013 -->
# Test Plan: APME OAuth on apps.crc.testing (Issue #96)

This guide is for anyone validating the fix for
[GitHub issue #96](https://github.com/RedHatOfficial/aap-demo/issues/96):
portal OAuth login failing on default CRC/MicroShift (`*.apps.crc.testing`).

**Branch under test:** `feat/apme-openshift-template`
**Related ADR:** [ADR-023: APME OpenShift Template Deployment](../../docs/adr/023-apme-openshift-template.md)

---

## What you are testing

After `aap-demo enable apme-eap`, signing in to the APME portal with AAP admin credentials should succeed. Before the fix, login failed with:

```text
Login failed; caused by Error: Failed to send POST request: fetch failed
```

The fix ensures that on MicroShift/CRC the portal backend uses `http://<aap-route>` for in-cluster token exchange and maps the AAP route hostname to the AAP Service ClusterIP via `hostAliases`.

---

## Prerequisites

| Requirement | How to check |
|-------------|--------------|
| OpenShift Local (CRC) with **microshift** preset | `crc config get preset` → `microshift` |
| Enough disk/RAM for AAP + portal | `crc status` |
| `kubectl`, `git`, and `aap-demo` on your PATH | `kubectl version --client`, `git --version`, `aap-demo version` |
| Network to pull images | Registry and Quay access for AAP and portal hub |

**Recommended:** Use a cluster where routes are on `apps.crc.testing` (default CRC domain). You do **not** need to configure `nip.io` for this test.

---

## Step 1: Get the branch

Choose **one** of the following, depending on whether you already have a clone of aap-demo.

### Option A — New clone

```bash
git clone https://github.com/RedHatOfficial/aap-demo.git
cd aap-demo
git fetch origin feat/apme-openshift-template
git checkout feat/apme-openshift-template
```

### Option B — Existing clone

```bash
cd /path/to/aap-demo
git fetch origin
git checkout feat/apme-openshift-template
git pull origin feat/apme-openshift-template
```

### Option C — Test from a fork

If you are validating changes on **your fork** before they land on `RedHatOfficial/aap-demo`:

```bash
git remote add myfork https://github.com/YOUR_USERNAME/aap-demo.git   # once
git fetch myfork feat/apme-openshift-template
git checkout feat/apme-openshift-template
```

Confirm you are on the right branch:

```bash
git branch --show-current
# Expected: feat/apme-openshift-template

git log -1 --oneline
```

Install or refresh the CLI wrapper (if you use the install script):

```bash
./install.sh
# or ensure your shell uses ./aap-demo.sh from this directory
```

---

## Step 2: Prepare a clean test cluster (recommended)

For a reliable first test, start from a fresh cluster:

```bash
aap-demo destroy          # skip if you have no cluster
aap-demo create
aap-demo deploy
```

Wait until AAP is healthy:

```bash
aap-demo status
aap-demo diagnose
```

Note your cluster route domain (console or AAP route). For this test it should look like `apps.crc.testing` or `apps.<something>.crc.testing`.

---

## Step 3: Enable APME and watch verification

```bash
aap-demo enable apme-eap
```

During deploy, the script should report OAuth checks when the portal route is up, for example:

- `AAP host URL: http://aap-aap-operator.apps.crc.testing`
- `AAP route host alias: … → <ClusterIP>`
- `OAuth token endpoint reachable (HTTP 400)` (or similar non-`000` code)

If verification warns, note the message and continue to Step 4 for manual checks.

---

## Step 4: Manual validation commands

Replace `aap-aap-operator.apps.crc.testing` with your actual AAP route hostname if different.

### 4.1 Portal route and pods

```bash
kubectl get route -n apme
kubectl get pods -n apme
```

All portal-related pods should be `Running` (portal may take 2–3 minutes after first deploy).

### 4.2 AAP host URL inside the portal pod

```bash
kubectl exec deploy/redhat-rhaap-portal -c backstage-backend -n apme -- printenv AAP_HOST_URL
```

**Pass:** URL starts with `http://` and matches your AAP route hostname.
**Fail:** `https://…`, empty, or a `.svc` cluster DNS name.

### 4.3 Host alias (DNS from inside the pod)

```bash
AAP_ROUTE=$(kubectl get route -n aap-operator -o jsonpath='{.items[0].spec.host}')
kubectl exec deploy/redhat-rhaap-portal -c backstage-backend -n apme -- getent hosts "$AAP_ROUTE"
```

**Pass:** Resolves to the AAP Service ClusterIP (not `127.0.0.1`, not empty).

```bash
kubectl get svc aap -n aap-operator -o jsonpath='{.spec.clusterIP}'
```

The IP from `getent hosts` should match this ClusterIP.

### 4.4 CoreDNS (optional but useful)

```bash
aap-demo diagnose
```

In the **DNS** section you should see either:

- `CoreDNS route rewrite configured (apps.crc.testing)` — pass, or
- A warning with fix hint — note it; OAuth may still work if `hostAliases` is correct.

### 4.5 Browser sign-in (primary acceptance test)

1. Open the portal URL from `aap-demo status` or:

   ```bash
   kubectl get route redhat-rhaap-portal -n apme -o jsonpath='https://{.spec.host}{"\n"}'
   ```

2. Choose **Sign in with RHAAP** (AAP OAuth).
3. Log in with AAP admin credentials (`aap-demo status` shows the password).

**Pass:** You land in the portal without `fetch failed`.
**Fail:** OAuth error in the UI; check portal backend logs:

```bash
kubectl logs deploy/redhat-rhaap-portal -c backstage-backend -n apme --tail=50
```

---

## Pass / fail criteria

| # | Check | Pass |
|---|--------|------|
| 1 | `AAP_HOST_URL` in portal pod | `http://<aap-route>` |
| 2 | `getent hosts <aap-route>` from portal pod | AAP Service ClusterIP |
| 3 | Deploy script OAuth verification | No failure warnings (or manual checks pass) |
| 4 | Browser OAuth login | Successful sign-in |
| 5 | `aap-demo diagnose` DNS | Rewrite present or documented warning only |

---

## Troubleshooting

| Symptom | What to try |
|---------|-------------|
| `fetch failed` on login | Re-run `aap-demo enable apme-eap`; re-check Steps 4.2–4.3 |
| Portal pod not ready | `kubectl get pods -n apme`; wait or `kubectl describe pod -n apme …` |
| Wrong branch | `git branch --show-current` must be `feat/apme-openshift-template` |
| Stale cluster after CRC restart | `aap-demo start` then `aap-demo enable apme-eap` |
| CoreDNS warning in diagnose | `aap-demo start` or `aap-demo deploy` to re-apply rewrite |

---

## Step 5: Report results

Comment on [issue #96](https://github.com/RedHatOfficial/aap-demo/issues/96) with:

- CRC preset and route domain (e.g. `apps.crc.testing`)
- Output of `printenv AAP_HOST_URL` and `getent hosts` (redact nothing sensitive — these are cluster-internal)
- Whether browser OAuth succeeded
- `aap-demo diagnose` DNS line (pass or warning)
- Any deploy verification warnings

---

## Appendix: Opening a pull request (contributors)

Use this section only if **you** made changes and want to propose them upstream. Testers who only validate the branch can skip this.

### 1. Fork and branch (if you have not already)

On GitHub, fork [RedHatOfficial/aap-demo](https://github.com/RedHatOfficial/aap-demo), then:

```bash
git remote add myfork https://github.com/YOUR_USERNAME/aap-demo.git
git checkout -b feat/apme-openshift-template   # or your feature branch
# make commits ...
git push -u myfork HEAD
```

### 2. Create the PR with GitHub CLI

From your repo root, with [gh](https://cli.github.com/) authenticated:

```bash
git push -u origin feat/apme-openshift-template   # if pushing to upstream branch (maintainers)

gh pr create \
  --repo RedHatOfficial/aap-demo \
  --base main \
  --head YOUR_USERNAME:feat/apme-openshift-template \
  --title "fix(apme-eap): OAuth login on apps.crc.testing (closes #96)" \
  --body "$(cat <<'EOF'
## Summary
- Fix APME portal OAuth on default CRC/MicroShift (`apps.crc.testing`)
- Use `http://` in-cluster AAP URL and MicroShift `hostAliases` for token exchange
- Add post-deploy OAuth verification and stronger `aap-demo diagnose` DNS check

## Test plan
- [ ] Checked out `feat/apme-openshift-template` per `addons/apme-eap/TEST_PLAN_ISSUE_96.md`
- [ ] `AAP_HOST_URL` is `http://<aap-route>` in portal pod
- [ ] Browser OAuth sign-in succeeds on `apps.crc.testing`
- [ ] `aap-demo diagnose` shows CoreDNS rewrite or documented warning

Closes #96
EOF
)"
```

Replace `YOUR_USERNAME` with your GitHub username when opening from a fork.

### 3. Create the PR in the browser

1. Go to https://github.com/RedHatOfficial/aap-demo/compare
2. Set **base** to `main` and **compare** to `feat/apme-openshift-template` (or your fork’s branch).
3. Use the title and test checklist from the `gh pr create` example above.
4. Link **Closes #96** in the description.

---

## Quick reference (copy/paste)

```bash
# Get branch
git clone https://github.com/RedHatOfficial/aap-demo.git && cd aap-demo
git fetch origin feat/apme-openshift-template && git checkout feat/apme-openshift-template

# Deploy and test
aap-demo create && aap-demo deploy && aap-demo enable apme-eap
kubectl exec deploy/redhat-rhaap-portal -c backstage-backend -n apme -- printenv AAP_HOST_URL
aap-demo diagnose
```
