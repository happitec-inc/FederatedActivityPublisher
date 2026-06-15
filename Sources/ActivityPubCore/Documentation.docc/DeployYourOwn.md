# Deploy Your Own ActivityPub Server

This guide walks through deploying your own instance of FederatedActivityPublisher. By the end, you will have a working ActivityPub server that federates with Mastodon and the fediverse.

## Prerequisites

- **AWS account** with IAM credentials that can create CloudFormation stacks, Lambda functions, DynamoDB tables, S3 buckets, SQS queues, CloudFront distributions, Route 53 hosted zones, and ACM certificates
- **A domain name** you control (e.g. `example.com`)
- **GitHub account** (for forking the repo and running workflows)
- **Swift 6.3** and **Docker** (only if using self-hosted runners; GitHub-hosted `ubuntu-latest` runners install these automatically)

## Time estimate

About 30 minutes of active work, plus DNS propagation wait time (minutes to hours).

## Step 1: Fork the repository

Fork [happitec-inc/FederatedActivityPublisher](https://github.com/happitec-inc/FederatedActivityPublisher) to your own GitHub account or organization.

## Step 2: Configure GitHub secrets

Go to your fork's **Settings > Secrets and variables > Actions** and add:

| Secret | Value |
|--------|-------|
| `AWS_ACCESS_KEY_ID` | Your IAM access key |
| `AWS_SECRET_ACCESS_KEY` | Your IAM secret key |

The IAM user needs broad permissions for initial deployment. A least-privilege policy can be crafted later from CloudTrail logs.

## Step 3: Configure GitHub variables

Under **Settings > Secrets and variables > Actions > Variables**, add:

| Variable | Value | Required |
|----------|-------|----------|
| `SERVER_DOMAIN` | Your server domain (e.g. `example.com`) | Yes |
| `HANDLE_DOMAIN` | Your handle domain (e.g. `example.com`) | Yes |
| `AWS_REGION` | AWS region for deployments (e.g. `us-east-1`) | No (defaults to `us-east-1`) |
| `RUNNER_LABELS_LINUX` | JSON array of runner labels (e.g. `["self-hosted", "linux"]`) | No (defaults to `ubuntu-latest`) |
| `PROXY_DISTRIBUTION_ID` | CloudFront distribution ID for parent-domain proxy | No (only for split DNS) |

For simple DNS mode (recommended), set `SERVER_DOMAIN` and `HANDLE_DOMAIN` to the same value.

See <doc:DNSSetup> for help choosing between simple and split DNS.

## Step 4: Deploy the bootstrap stack

The bootstrap stack creates the Route 53 hosted zone and ACM wildcard certificate.

1. Go to **Actions > Deploy Bootstrap Stack**
2. Click **Run workflow**
3. Set **domain-name** to your domain (e.g. `example.com`)
4. Set **dns-mode** to `simple` (or `split` if using a subdomain)
5. Run the workflow

**Important:** The workflow will appear to hang during ACM certificate validation. This is normal -- ACM uses DNS validation, and the certificate is created in the same hosted zone, so it validates automatically. It can take 5-30 minutes.

6. Check the workflow output for the **NameServers** values (four NS records)

## Step 5: Set up DNS

**Simple mode:** Go to your domain registrar and change the nameservers to the four values from step 4.

**Split mode:** Add an NS record in your parent zone delegating the subdomain to the four nameservers.

Wait for DNS propagation. You can check with:
```bash
dig +short NS example.com
```

The output should show the four Route 53 nameservers.

## Step 6: Deploy the environment stack

The environment stack creates DynamoDB, S3, and SQS resources.

1. Go to **Actions > Deploy Environment Stack**
2. Click **Run workflow**
3. Choose `stage` (start with stage, deploy prod later)
4. Run the workflow

## Step 7: Deploy the app stack

The app stack deploys all Lambda functions (with OpenSSL bundled), API Gateway, and CloudFront using nested stacks.

1. Go to **Actions > Deploy Stage**
2. Click **Run workflow**
3. Run the workflow (first manual run takes the full path)

This is the longest step (~5-10 minutes). It builds Swift Lambda functions in Docker, packages them, and deploys via SAM.

After deployment, the workflow output shows stack outputs including the CloudFront domain and API endpoints.

## Step 8: Verify the server

```bash
# NodeInfo (should return server metadata)
curl -s https://example.com/.well-known/nodeinfo | jq .

# Should return a link to /nodeinfo/2.1
curl -s https://example.com/nodeinfo/2.1 | jq .
```

If these return valid JSON, the server is running.

## Step 9: Provision your first actor

### Option A: GitHub Actions workflow (recommended)

1. Go to **Actions > Provision Actor**
2. Click **Run workflow**
3. Enter username, display name, and optional summary
4. Choose the stage
5. Run the workflow
6. **Copy the bearer token** from the workflow summary -- it is displayed once and cannot be retrieved later

The workflow creates the actor profile in DynamoDB, generates an RSA keypair in SSM, and stores a per-account bearer token as a `TOKEN#<sha256-hash>` record in DynamoDB. Each account gets its own independent token.

### Option B: CLI on a machine with Swift and AWS credentials

```bash
# Provision the actor (RSA keypair to SSM, profile to DynamoDB)
swift run ActivityProvisioner provision \
  --stage stage \
  --username mybot \
  --display-name "My Bot" \
  --summary "An ActivityPub bot" \
  --server-domain example.com \
  --handle-domain example.com

# Mint a bearer token (printed once; --out also writes it to a file)
swift run ActivityProvisioner mint-token \
  --stage stage \
  --username mybot \
  --out token.txt
```

Provisioning the actor and minting its token are separate steps. The token is shown only at mint time — store it securely and never commit it. See <doc:ManagingActorsAndTokens> for the full set of token commands (list, rotate, revoke) and the reasoning behind minting tokens locally rather than in CI.

## Step 10: Verify the actor

```bash
# WebFinger
curl -s "https://example.com/.well-known/webfinger?resource=acct:mybot@example.com" | jq .

# Actor JSON-LD
curl -s -H "Accept: application/activity+json" "https://example.com/users/mybot" | jq .

# Search from any Mastodon instance
# Search for @mybot@example.com
```

## Step 11: First post

Get the Client API URL from the app stack outputs:
```bash
aws cloudformation describe-stacks \
  --stack-name activity-app-stage \
  --query "Stacks[0].Outputs[?OutputKey=='ClientApiUrl'].OutputValue" \
  --output text \
  --region us-east-1
```

Post:
```bash
API_URL="<client-api-url-from-above>"
TOKEN="<bearer-token-from-step-9>"

curl -X POST "$API_URL/api/v1/statuses" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"status": "Hello fediverse! This is my first post from my own ActivityPub server."}'
```

## Going to production

Once you have verified everything works on `stage`:

1. Re-run the environment workflow with `prod`
2. Set `ACTIVITY_DISTRIBUTION_ID_PROD` and `CLIENT_API_DOMAIN_PROD` repository variables after the first prod deploy
3. Create a GitHub release with a `v`-prefixed tag (e.g. `v1.0.0`) to trigger a prod deploy via `deploy-prod.yml`
4. Re-provision your actor with `--stage prod` (or re-run the Provision Actor workflow targeting prod)

## Troubleshooting

### ACM certificate stuck in "Pending validation"

The certificate validates via DNS records in the hosted zone created by the same stack. If it is stuck:
- Verify the hosted zone NS records match your registrar / parent zone
- Check the Route 53 console for CNAME validation records
- Wait longer (can take up to 30 minutes)

### CloudFront returns 403

- The DNS record may not have propagated yet
- Check that the CloudFront distribution's CNAME alias matches your domain
- Verify the ACM certificate is in `us-east-1` (required for CloudFront)

### WebFinger returns empty or 404

- The actor has not been provisioned yet
- In split DNS mode, ensure the WebFinger redirect is configured on the handle domain

### swift build fails on GitHub-hosted runner

- GitHub-hosted `ubuntu-latest` does not have Swift pre-installed. The workflow installs it, but this adds ~2 minutes.
- If disk space is an issue, consider self-hosted runners (see README.md for runner label configuration).
