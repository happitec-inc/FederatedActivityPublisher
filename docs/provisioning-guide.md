# Provisioning Guide (moved)

This guide has moved to the DocC documentation catalog:

**[ProvisioningGuide](../Sources/ActivityPubCore/Documentation.docc/ProvisioningGuide.md)**

The version that previously lived here described an outdated token flow
(retrieving the bearer token from SSM). Tokens are now per-account: the raw
token is shown **once** in the Provision Actor workflow summary, and only its
SHA-256 hash is stored in DynamoDB. The DocC guide documents the current flow.
