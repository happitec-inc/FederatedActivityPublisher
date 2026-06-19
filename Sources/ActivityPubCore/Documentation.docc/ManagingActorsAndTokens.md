# Managing Actors and Tokens

Provision actors and manage their bearer tokens with the `ActivityProvisioner` CLI.

## Overview

An account on this server is two things: an actor record and one or more bearer tokens.

- The **actor** is a `PROFILE` record in the `activity-{stage}` DynamoDB table (`PK = ACTOR#<username>`, `SK = PROFILE`) plus a 2048-bit RSA private key stored as a SecureString in SSM Parameter Store at `/activity/{stage}/keys/{username}`. The public key PEM is embedded in the profile record; the server uses the private key to sign outbound activities.
- A **bearer token** authorizes calls to the client posting API (`POST /api/v1/statuses`, `POST /api/v2/media`, `PATCH /api/v1/accounts/update_credentials`). The raw token is never stored. Only its SHA-256 hash is written to DynamoDB as a `TOKEN#<sha256>` record (`PK = TOKEN#<hash>`, `SK = META`), alongside the username, scope, creation timestamp, and a TTL. On each request the server hashes the presented token and looks up that record, so the plaintext exists only on the machine that minted it and in whatever the operator does with it afterward.

An actor can have several valid tokens at once, and each account's tokens are independent of every other account's.

The `ActivityProvisioner` CLI handles both halves: it provisions actors and it mints, lists, rotates, and revokes their tokens. It runs on your own machine (or a trusted CI runner) using the standard AWS credential chain — `~/.aws/credentials`, environment variables, an instance role, and so on. It is not deployed as a Lambda.

## Building and running the CLI

```bash
swift build --product ActivityProvisioner
```

Run it through SwiftPM:

```bash
swift run ActivityProvisioner <subcommand> ...
```

Or invoke the built binary directly:

```bash
.build/debug/ActivityProvisioner <subcommand> ...
```

Every subcommand needs to know which DynamoDB table to act on. Pass `--stage <stage>` and the table name is derived as `activity-<stage>`, or pass `--table-name` to name the table explicitly. The token subcommands accept either; `provision` takes `--stage` (and an optional `--table-name` override). `--region` defaults to `us-east-1`.

## Provisioning an actor

```bash
swift run ActivityProvisioner provision \
  --stage stage \
  --username mybot \
  --display-name "My Bot" \
  --summary "An ActivityPub bot." \
  --server-domain activity.example.com \
  --handle-domain example.com
```

This generates the RSA keypair, stores the private key in SSM, and writes the actor profile to DynamoDB with follower, following, and status counts set to zero. It does **not** mint a token — that is a separate step, so that token issuance can be audited and repeated independently of actor creation.

`--server-domain` is the host that serves the actor's URLs (e.g. `activity.example.com`); `--handle-domain` is the part after the `@` in the handle (e.g. `example.com`, producing `@mybot@example.com`). In simple DNS mode these are the same value. See <doc:DNSSetup>.

## Minting a token

```bash
swift run ActivityProvisioner mint-token \
  --stage stage \
  --username mybot \
  --out token.txt
```

The raw token is printed to stdout, and with `--out` it is also written (and only the token, nothing else) to the named file. Run `chmod 600 token.txt` afterward. The defaults are `--scope "read write"` and `--ttl-days 365`; override either when you need a narrower scope or a shorter lifetime.

This is the only moment the plaintext token exists in a form you can copy. The DynamoDB record holds the hash, not the token, so a lost token cannot be recovered — mint a new one and revoke the old.

## Listing tokens

```bash
swift run ActivityProvisioner list-tokens --stage stage
swift run ActivityProvisioner list-tokens --stage stage --username mybot
```

This prints one line per token record: username, the `TOKEN#<hash>` primary key, creation time, scope, and TTL. It never prints plaintext, because the plaintext is not stored. Use it to audit which accounts have live tokens and when they were issued.

## Rotating a token

```bash
swift run ActivityProvisioner rotate-token \
  --stage stage \
  --username mybot \
  --out new-token.txt
```

Rotation mints a new token first, then deletes every other token for that username. Because the new token is written before the old ones are removed, there is no window in which the account has zero valid tokens — a client switched over to the new token keeps working throughout. As with `mint-token`, the new token is shown once on stdout and optionally written to `--out`.

## Revoking a token

Revoke all tokens for a username:

```bash
swift run ActivityProvisioner revoke-token --stage stage --username mybot
```

Or revoke a single token by its hash (with or without the `TOKEN#` prefix):

```bash
swift run ActivityProvisioner revoke-token \
  --stage stage \
  --hash 4f3c...e91a
```

Provide exactly one of `--username` or `--hash`. Add `--dry-run` to print what would be deleted without deleting anything:

```bash
swift run ActivityProvisioner revoke-token --stage stage --username mybot --dry-run
```

## Token lifecycle

The normal arc of a token is issue, use, rotate, revoke:

1. **Issue** a token with `mint-token` after provisioning the actor.
2. **Use** it in the `Authorization: Bearer <token>` header on client API calls.
3. **Rotate** it periodically with `rotate-token`, which mints a replacement and revokes the old tokens in one step with no zero-token gap.
4. **Revoke** with `revoke-token` when an account is retired or a token is suspected compromised.

`list-tokens` supports all of these by showing what is currently valid.

## Security posture

Tokens are minted off-CI, on purpose. This repository is public, and a GitHub Actions log or job summary is readable by anyone who can see the run. A raw token printed there would be exposed. There is therefore no provisioning workflow: both actor provisioning and token minting happen locally with this CLI, where the plaintext stays on your machine.

When a token is printed on mint or rotate, treat it as a credential:

- Store it in a secrets manager or your OS keychain, not in a plain file you forget about.
- If you used `--out`, `chmod 600` the file and delete it once the token is stored elsewhere.
- Never commit a token to a repository or paste it into an issue, chat, or log.
- If a token leaks, revoke it and rotate immediately.

## Related

- <doc:DeployYourOwn> — provisioning fits into step 9 of standing up a new instance.
- <doc:ProvisioningAccounts> — actor profile and bearer-token model.
- <doc:AuthenticationOverview> — how the server validates bearer tokens per request.
