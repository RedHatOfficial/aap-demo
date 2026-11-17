# Changelog

## Unreleased

- Fix Keycloak OIDC configuration for Automation Orchestrator login and group mapping.
- Add audience, username, and email claims required by AAP Gateway and Automation Orchestrator.
- Ensure generated test users have complete profile fields for OIDC authentication.
- Reconcile claims and user profile fields when re-enabling an existing Keycloak realm.
- Add static and live regression coverage for generated claims and user configuration.
