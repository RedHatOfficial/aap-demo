# Architecture Decision Records (ADR)

This directory contains Architecture Decision Records for the aap-demo project.

## What is an ADR?

An Architecture Decision Record (ADR) captures an important architectural decision made along with its
context and consequences. ADRs help us understand why certain decisions were made and provide a
historical record of the project's evolution.

## ADR Format

We use a simplified ADR format based on [Michael Nygard's template](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions):

- **Title**: Short noun phrase
- **Status**: Proposed | Accepted | Deprecated | Superseded
- **Context**: What is the issue we're seeing that motivates this decision?
- **Decision**: What is the change we're proposing/doing?
- **Consequences**: What becomes easier or more difficult because of this change?

## Index

| ADR | Title | Status |
|-----|-------|--------|
| [002](002-portal-vm-macos-deployment.md) | Portal VM Addon for macOS QEMU Deployment | Accepted |

## Creating a New ADR

1. Copy the template: `cp docs/adr/000-template.md docs/adr/XXX-title.md`
2. Increment the number (XXX)
3. Fill in the sections
4. Update this index
5. Commit with message: `docs(adr): Add ADR-XXX: Title`
