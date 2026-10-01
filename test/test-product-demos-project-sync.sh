#!/usr/bin/env bash
# Regression test for the Product Demos bootstrap project sync.
# The AAP project API does not start an SCM update merely because a project is
# created or patched, so the addon must call the explicit update endpoint.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_SCRIPT="${ROOT_DIR}/addons/product-demos-base/deploy.sh"

sync_block=$(sed -n '/# A project create\/patch/,/# REGISTER EXECUTION ENVIRONMENT/p' "$DEPLOY_SCRIPT")

if ! grep -Fq -- '-X POST' <<<"$sync_block" || \
   ! grep -Fq '/projects/${PROJECT_ID}/update/' <<<"$sync_block"; then
  echo "FAIL: product-demos must trigger an explicit AAP project update" >&2
  exit 1
fi

if ! grep -Fq 'job_explanation' <<<"$sync_block"; then
  echo "FAIL: project sync failures must include AAP job details" >&2
  exit 1
fi

if ! grep -Fq 'scm_clean' <<<"$sync_block"; then
  echo "FAIL: bootstrap project sync must clean intentional overlay modifications" >&2
  exit 1
fi

echo "PASS: product-demos explicitly starts, cleans, and diagnoses project sync"
