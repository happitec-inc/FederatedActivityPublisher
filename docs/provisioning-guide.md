# Provisioning Guide (moved)

This guide has moved to the DocC documentation catalog:

**[ProvisioningGuide](../Sources/ActivityPubCore/Documentation.docc/ProvisioningGuide.md)**

The version that previously lived here described an outdated token flow
(retrieving the bearer token from SSM). Tokens are now per-account and minted
via the `ActivityProvisioner` CLI: the raw token is shown **once** on the
terminal (and optionally written to an `--out` file), and only its SHA-256 hash
is stored in DynamoDB. The DocC guide documents the current flow.
