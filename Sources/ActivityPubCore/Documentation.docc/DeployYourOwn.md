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
| `PROXY_DISTRIBUTION_ID` | CloudFront distribution ID for cross-invalidation | No (only for split DNS) |
| `ACTIVITY_DISTRIBUTION_ID_STAGE` | CloudFront distribution ID for stage (set after first deploy) | No (set after step 7) |
| `ACTIVITY_DISTRIBUTION_ID_PROD` | CloudFront distribution ID for prod (set after first prod deploy) | No (set after going to production) |
| `CLIENT_API_DOMAIN_STAGE` | Client API Gateway domain for stage (set after first deploy) | No (set after step 7) |
| `CLIENT_API_DOMAIN_PROD` | Client API Gateway domain for prod | No (set after going to production) |

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

The app stack deploys all Lambda functions, API Gateway, and CloudFront via nested CloudFormation stacks.

1. Go to **Actions > Build App**
2. Click **Run workflow**
3. Choose `stage`
4. Run the workflow

This triggers `build.yml`, which builds all Lambda handlers and packages the template. When it completes, `deploy.yml` triggers automatically and deploys to the selected stage.

This is the longest step (~7 minutes with warm caches, 20+ minutes on first run). The build runs on a `linux_large` runner with Docker, and the deploy runs on `ubuntu-latest`.

After deployment, the deploy workflow output shows stack outputs including the CloudFront distribution ID, domain, and API endpoints. Copy the `CloudFrontDistributionId` and `ClientApiUrl` values -- you will need them for repository variables.

## Step 8: Verify the server

```bash
# NodeInfo (should return server metadata)
curl -s https://example.com/.well-known/nodeinfo | jq .

# Should return a link to /nodeinfo/2.1
curl -s https://example.com/nodeinfo/2.1 | jq .
```

If these return valid JSON, the server is running.

## Step 9: Provision your first actor

### Option A: GitHub Actions workflow

1. Go to **Actions > Provision Actor**
2. Click **Run workflow**
3. Enter username, display name, and optional summary
4. Choose the stage
5. Run the workflow
6. **Retrieve the bearer token** using the AWS CLI command shown in the workflow summary

### Option B: CLI on a machine with Swift and AWS credentials

```bash
swift run ActivityProvisioner \
  --stage stage \
  --username mybot \
  --display-name "My Bot" \
  --summary "An ActivityPub bot" \
  --server-domain example.com \
  --handle-domain example.com

# Create a bearer token
TOKEN=$(openssl rand -hex 32)
aws ssm put-parameter \
  --name "/activity/stage/keys/client-token" \
  --type SecureString \
  --value "mybot:$TOKEN" \
  --overwrite \
  --region us-east-1
echo "Bearer token: $TOKEN"
```

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

1. Set repository variables from your stage deploy outputs:
   - `ACTIVITY_DISTRIBUTION_ID_STAGE` -- CloudFront distribution ID from stage deploy output
   - `CLIENT_API_DOMAIN_STAGE` -- Client API Gateway domain from stage deploy output
2. Re-run the environment workflow with `prod`
3. Re-run the build workflow with `prod` (deploy triggers automatically)
4. Set the prod repository variables:
   - `ACTIVITY_DISTRIBUTION_ID_PROD` -- CloudFront distribution ID from prod deploy output
   - `CLIENT_API_DOMAIN_PROD` -- Client API Gateway domain from prod deploy output
5. Re-provision your actor with `--stage prod`
6. Or: create a GitHub release with a `v`-prefixed tag (e.g. `v1.0.0`) to trigger a prod deploy automatically

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
