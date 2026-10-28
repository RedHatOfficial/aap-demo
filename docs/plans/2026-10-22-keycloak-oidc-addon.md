# Keycloak OIDC lab addon

## Goal

Provide a repeatable Keycloak OIDC provider for local AAP and Automation Orchestrator
authentication testing without changing either product's authentication configuration
automatically.

## Scope

- Add `aap-demo enable keycloak` and `aap-demo disable keycloak`.
- Run one pinned Keycloak container in `aap-demo-keycloak`.
- Expose Keycloak through an HTTPS OpenShift Route.
- Import realm `aap-lab` with test users, groups, group claims, and separate AAP/AO confidential clients.
- Persist generated lab credentials only under `~/.aap-demo/keycloak` with mode `0600`.
- Report issuer, client IDs, redirect hosts, and credential-file paths without printing secrets.
- Document manual AAP 2.6 Gateway and AO IdP configuration, including callback URL discovery.

## Non-goals

- No AAP or AO authentication mutation during addon enable.
- No shared AAP/AO client.
- No production Keycloak profile, external database, HA, or TLS certificate management.
- No AAP 2.6/2.7 coexistence changes.

## Validation

- Shell tests verify addon dispatch, manifest safety, and secret redaction.
- Live test verifies namespace, Deployment, Route, readiness, realm discovery, groups, and clients.
- Manual browser validation configures AAP and AO using generated client data.

## Rollback

`aap-demo disable keycloak` removes only `aap-demo-keycloak` and its saved local
credential directory remains available for inspection or explicit user removal.
Re-enable recreates the provider and credentials when files are absent.
