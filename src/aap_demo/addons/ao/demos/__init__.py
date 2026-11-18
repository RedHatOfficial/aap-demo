"""AO demo provisioning and import, run in-process by the native addon (ADR-045).

Copies of addons/ao/scripts/*.py, which stay frozen for aap-demo-v1. These take
the TLS context and tokens as arguments instead of disabling verification or
reading the environment.
"""
