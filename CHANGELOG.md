# Changelog

## Unreleased

- AO's `ollama` provider now uses Ollama running on the host instead of an in-cluster pod (ADR-046).
  `enable ao` checks that Ollama runs and the cluster reaches it, and uses a model you have pulled.
  aap-demo no longer installs Ollama or downloads a default model (`qwen2.5:3b` is gone).
- `aap-demo create` turns on CRC `host-network-access` for a new VM on macOS and Windows.
- `aap-demo enable ollama` is removed from the new command; `aap-demo disable ollama` removes an
  in-cluster Ollama from an earlier release.
- AO's `external` provider accepts `http://` URLs and hosts outside aap-demo's routes.
- Fix Keycloak OIDC configuration for Automation Orchestrator login and group mapping.
- Add audience, username, and email claims required by AAP Gateway and Automation Orchestrator.
- Ensure generated test users have complete profile fields for OIDC authentication.
- Reconcile claims and user profile fields when re-enabling an existing Keycloak realm.
- Add static and live regression coverage for generated claims and user configuration.
