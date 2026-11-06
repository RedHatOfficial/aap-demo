# APME plugin artifact staging

Plugin packs are resolved at image-build time from the configured external source
(by default `ansible/ansible-rhdh-plugins`). The resolver validates the GitHub Actions
artifact, and `Containerfile.ci` bakes the six verified plugins into the portal image.

No plugin archive is checked into this repository or pushed to the cluster at runtime.
