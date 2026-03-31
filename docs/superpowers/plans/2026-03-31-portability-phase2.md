# Portability Phase 2: Enable External Deployers

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Enable someone outside the `happitec-inc` GitHub org to fork this repo and deploy their own ActivityPub server, end to end. Introduce a "simple DNS" mode (single domain, no proxy) as the default, keeping the current split-domain proxy architecture as an advanced option.

**Estimated time:** ~6-8 hours

**Audit reference:** [Issue #99 -- Portability Audit](https://github.com/happitec-inc/FederatedActivityPublisher/issues/99)
**Tracking issue:** [Issue #103 -- Portability Phase 2](https://github.com/happitec-inc/FederatedActivityPublisher/issues/103)
**Prerequisite:** Phase 1 (PR #102) merged.

**Key design principle:** "When possible, fork so it's easier for another developer." The split DNS setup (handle domain at `happitec.com`, server at `activity.happitec.com`) is the complex path. The simple path is running everything at one domain. The plan supports BOTH paths with a clear fork point, not forcing the complex path on everyone.

---

## Task 1: Simple DNS mode in bootstrap template

**File:** `activity-bootstrap/template.yaml`

The bootstrap template currently creates a hosted zone for `activity.happitec.com` (a subdomain), which requires NS delegation from a parent zone. In simple mode, the hosted zone is for the user's full domain directly (e.g. `example.com`), and no NS delegation is needed because the user sets their registrar's nameservers to Route 53 directly.

### 1.1 Add `DnsMode` parameter

- [ ] Add a `DnsMode` parameter to `activity-bootstrap/template.yaml`:

```yaml
Parameters:
  DomainName:
    Type: String
    Default: activity.happitec.com
    Description: Base domain for the ActivityPub server

  DnsMode:
    Type: String
    Default: simple
    AllowedValues:
      - simple
      - split
    Description: >
      DNS architecture mode.
      simple: ServerDomain and HandleDomain are the same. The hosted zone
      is for this domain directly. Set your registrar NS records to Route 53.
      split: ServerDomain is a subdomain of HandleDomain (e.g. activity.example.com
      under example.com). Requires NS delegation from the parent zone.
```

### 1.2 Add condition

- [ ] Add a condition:

```yaml
Conditions:
  IsSplitDns: !Equals [!Ref DnsMode, split]
```

### 1.3 Update outputs

- [ ] Update the `NameServers` output description to clarify context:

```yaml
  NameServers:
    Description: >
      NS records. In simple mode, set these as your domain registrar's
      nameservers. In split mode, add these as NS records in the parent zone.
    Value: !Join
      - ", "
      - !GetAtt HostedZone.NameServers
```

### 1.4 Update bootstrap samconfig.toml

- [ ] Read `activity-bootstrap/samconfig.toml` and add `DnsMode` to the parameter overrides with default `simple`.

### 1.5 Update bootstrap workflow

- [ ] Edit `.github/workflows/bootstrap.yml` to accept `DnsMode` as a workflow dispatch input:

```yaml
on:
  workflow_dispatch:
    inputs:
      domain-name:
        description: "Base domain for the ActivityPub server"
        required: true
        default: "activity.happitec.com"
      dns-mode:
        description: "DNS mode (simple = single domain, split = subdomain of parent)"
        required: true
        type: choice
        options:
          - simple
          - split
        default: simple
```

- [ ] Replace the existing `sam deploy` step. The current workflow uses `--config-file` to reference `samconfig.toml`. Remove `--config-file` entirely and use explicit CLI flags and `--parameter-overrides` instead (the workflow inputs are the source of truth, not the config file):

```yaml
      - name: SAM deploy
        run: |
          sam deploy \
            --template-file .aws-sam/build/template.yaml \
            --stack-name activity-bootstrap \
            --capabilities CAPABILITY_IAM \
            --no-confirm-changeset \
            --no-fail-on-empty-changeset \
            --region us-east-1 \
            --parameter-overrides \
              DomainName=${{ inputs.domain-name }} \
              DnsMode=${{ inputs.dns-mode }}
```

> **Note:** This intentionally drops `--config-file`. The `samconfig.toml` is retained for local `sam deploy` convenience, but the CI workflow should use explicit parameters from workflow inputs so there is a single source of truth per invocation.

### Verification

- The bootstrap template change is purely additive -- the new parameter defaults to `simple`, so existing deployments are unaffected (they would redeploy with `DnsMode=split` explicitly).
- No resources change structurally -- the hosted zone and certificate work identically in both modes. The difference is only in what the deployer does with the NS records (registrar vs. parent zone delegation).

---

## Task 2: Simple DNS mode in app template

**File:** `activity-app/template.yaml`

When `HandleDomain == ServerDomain` (simple mode), the app template can be simpler: no WebFinger proxy needed, no `/@` rewriting, no second CloudFront distribution, no cross-invalidation.

### 2.1 Add `IsSimpleDns` condition

- [ ] Add a condition to `activity-app/template.yaml` that detects simple mode. Simple mode means `ServerDomain == HandleDomain`:

```yaml
Conditions:
  IsProd: !Equals [!Ref Stage, prod]
  IsSimpleDns: !Equals [!Ref ServerDomain, !Ref HandleDomain]
```

### 2.2 Replace hardcoded `activity.happitec.com` in CloudFront Alias

- [ ] Line 548: Replace the hardcoded `activity.happitec.com` with the `ServerDomain` parameter. The current template has:

```yaml
        Aliases:
          - !If [IsProd, "activity.happitec.com", !Sub "${Stage}.activity.happitec.com"]
```

Replace with:

```yaml
        Aliases:
          - !If [IsProd, !Ref ServerDomain, !Sub "${Stage}.${ServerDomain}"]
```

### 2.3 Replace hardcoded `activity.happitec.com` in Route 53 record

- [ ] Line 658: Replace:

```yaml
      Name: !If [IsProd, "activity.happitec.com", !Sub "${Stage}.activity.happitec.com"]
```

With:

```yaml
      Name: !If [IsProd, !Ref ServerDomain, !Sub "${Stage}.${ServerDomain}"]
```

### 2.4 Replace hardcoded `activity.happitec.com` in output

- [ ] Line 678: Replace:

```yaml
    Value: !If [IsProd, "activity.happitec.com", !Sub "${Stage}.activity.happitec.com"]
```

With:

```yaml
    Value: !If [IsProd, !Ref ServerDomain, !Sub "${Stage}.${ServerDomain}"]
```

### 2.5 Make `ProxyDistributionId` cross-invalidation conditional

- [ ] The `PostFunction` and `ProfileUpdateFunction` have IAM policies referencing `ProxyDistributionId`. When it is empty, the `arn:aws:cloudfront::...:distribution/` resource is invalid. Add a condition:

```yaml
Conditions:
  IsProd: !Equals [!Ref Stage, prod]
  IsSimpleDns: !Equals [!Ref ServerDomain, !Ref HandleDomain]
  HasCrossDistribution: !Not [!Equals [!Ref ProxyDistributionId, ""]]
```

- [ ] For `PostFunction` policies (line 88-93), use `!If` at the **Resource** level inside the existing Statement to conditionally include the cross-distribution ARN. Wrapping entire `Statement` blocks in `!If` is not valid SAM/CloudFormation syntax for `Policies`. Instead, use `AWS::NoValue` to exclude the second ARN when not needed:

```yaml
        - Statement:
            - Effect: Allow
              Action: cloudfront:CreateInvalidation
              Resource:
                - !Sub "arn:aws:cloudfront::${AWS::AccountId}:distribution/${CloudFrontDistribution}"
                - !If
                  - HasCrossDistribution
                  - !Sub "arn:aws:cloudfront::${AWS::AccountId}:distribution/${ProxyDistributionId}"
                  - !Ref AWS::NoValue
```

- [ ] Apply the same pattern to `ProfileUpdateFunction` policies (line 174-179).

### 2.6 Update app workflow parameter overrides

- [ ] Edit `.github/workflows/app.yml` to make `ServerDomain` and `HandleDomain` configurable via repository variables. Replace lines 103-104:

```yaml
              ServerDomain=${{ vars.SERVER_DOMAIN }} \
              HandleDomain=${{ vars.HANDLE_DOMAIN }} \
```

> **Critical -- happitec-inc deployment:** The `happitec-inc` repo uses split DNS where the CloudFront alias is `activity.happitec.com`, not `happitec.com`. After this change, `happitec-inc` **must** set the repository variable `SERVER_DOMAIN=activity.happitec.com` (and `HANDLE_DOMAIN=happitec.com`). Without this, the CloudFront alias would resolve to `happitec.com`, which is the handle domain -- not the server domain -- breaking the deployment. Add this as a migration step in the PR description.

- [ ] Document these new repository variables in `README.md` under the "Repository Variables" table:

| Variable | Used by | Default | Description |
|----------|---------|---------|-------------|
| `SERVER_DOMAIN` | app | `happitec.com` | Domain where the ActivityPub server runs. For happitec-inc, set to `activity.happitec.com`. In simple mode, same as handle domain. In split mode, the subdomain (e.g. `activity.example.com`). |
| `HANDLE_DOMAIN` | app | `happitec.com` | Domain used in handles (`@user@example.com`). Permanent once federated. |

### Verification

- Deploying with `ServerDomain=example.com HandleDomain=example.com` (simple mode) should produce a working single-domain setup with no references to `activity.happitec.com`.
- Deploying with `ServerDomain=activity.example.com HandleDomain=example.com` (split mode) should produce the current behavior.
- The `ProxyDistributionId` conditional prevents IAM errors when the parameter is empty.

---

## Task 3: Actor provisioning workflow

**File:** `.github/workflows/provision-actor.yml` (new file)

Currently, provisioning an actor requires SSH into a Linux VM with Swift 6.3 and AWS credentials. This workflow provides a GitHub Actions alternative with manual dispatch.

### 3.1 Create the workflow

- [ ] Create `.github/workflows/provision-actor.yml`:

```yaml
name: Provision Actor

on:
  workflow_dispatch:
    inputs:
      username:
        description: "Actor username (lowercase, no spaces, e.g. 'myapp')"
        required: true
        type: string
      display-name:
        description: "Display name (e.g. 'My App')"
        required: true
        type: string
      summary:
        description: "Bio / summary text"
        required: false
        type: string
        default: ""
      stage:
        description: "Target environment"
        required: true
        type: choice
        options:
          - stage
          - prod
        default: stage

permissions:
  contents: read

jobs:
  provision:
    runs-on: ${{ vars.RUNNER_LABELS_LINUX && fromJSON(vars.RUNNER_LABELS_LINUX) || 'ubuntu-latest' }}
    steps:
      - name: Clean workspace (self-hosted)
        if: ${{ vars.RUNNER_LABELS_LINUX }}
        run: |
          sudo rm -rf .build/
          sudo git clean -fdx -e .git || true

      - name: Checkout
        uses: actions/checkout@v6
        with:
          clean: false

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v6
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: us-east-1

      - name: Install Swift
        run: |
          if swift --version 2>/dev/null | grep -q "6.3"; then
            echo "Swift 6.3 already installed"
          else
            ARCH=$(uname -m)
            if [ "$ARCH" = "aarch64" ]; then
              SWIFT_URL="https://download.swift.org/swift-6.3-release/ubuntu2404-aarch64/swift-6.3-RELEASE/swift-6.3-RELEASE-ubuntu24.04-aarch64.tar.gz"
            else
              SWIFT_URL="https://download.swift.org/swift-6.3-release/ubuntu2404/swift-6.3-RELEASE/swift-6.3-RELEASE-ubuntu24.04.tar.gz"
            fi
            curl -fsSL "$SWIFT_URL" | sudo tar xz --strip-components=2 -C /usr/local
          fi
          swift --version

      - name: Build ActivityProvisioner
        run: swift build --product ActivityProvisioner

      - name: Provision actor
        run: |
          swift run ActivityProvisioner \
            --stage ${{ inputs.stage }} \
            --username "${{ inputs.username }}" \
            --display-name "${{ inputs.display-name }}" \
            --summary "${{ inputs.summary }}" \
            --server-domain "${{ vars.SERVER_DOMAIN }}" \
            --handle-domain "${{ vars.HANDLE_DOMAIN }}"

      - name: Generate bearer token
        run: |
          TOKEN=$(openssl rand -hex 32)
          echo "::add-mask::$TOKEN"
          aws ssm put-parameter \
            --name "/activity/${{ inputs.stage }}/keys/client-token" \
            --type SecureString \
            --value "${{ inputs.username }}:$TOKEN" \
            --overwrite \
            --region us-east-1
          echo "## Actor Provisioned" >> "$GITHUB_STEP_SUMMARY"
          echo "" >> "$GITHUB_STEP_SUMMARY"
          echo "**Username:** ${{ inputs.username }}" >> "$GITHUB_STEP_SUMMARY"
          echo "**Stage:** ${{ inputs.stage }}" >> "$GITHUB_STEP_SUMMARY"
          echo "**Handle:** @${{ inputs.username }}@${{ vars.HANDLE_DOMAIN }}" >> "$GITHUB_STEP_SUMMARY"
          echo "" >> "$GITHUB_STEP_SUMMARY"
          echo "The bearer token has been stored in SSM at:" >> "$GITHUB_STEP_SUMMARY"
          echo "\`/activity/${{ inputs.stage }}/keys/client-token\`" >> "$GITHUB_STEP_SUMMARY"
          echo "" >> "$GITHUB_STEP_SUMMARY"
          echo "Retrieve it with:" >> "$GITHUB_STEP_SUMMARY"
          echo "\`\`\`" >> "$GITHUB_STEP_SUMMARY"
          echo "aws ssm get-parameter --name /activity/${{ inputs.stage }}/keys/client-token --with-decryption --query Parameter.Value --output text" >> "$GITHUB_STEP_SUMMARY"
          echo "\`\`\`" >> "$GITHUB_STEP_SUMMARY"
          echo "" >> "$GITHUB_STEP_SUMMARY"
          echo "**Warning:** This overwrites the shared client-token parameter." >> "$GITHUB_STEP_SUMMARY"
          echo "Only one account can post at a time per environment." >> "$GITHUB_STEP_SUMMARY"

      - name: Verify actor
        run: |
          DOMAIN="${{ vars.SERVER_DOMAIN }}"
          HANDLE_DOMAIN="${{ vars.HANDLE_DOMAIN }}"
          echo "Waiting 10s for CloudFront propagation..."
          sleep 10
          echo "--- WebFinger ---"
          curl -sf "https://$DOMAIN/.well-known/webfinger?resource=acct:${{ inputs.username }}@$HANDLE_DOMAIN" | jq . || echo "WebFinger not yet available (may take a few minutes for DNS/cache)"
          echo ""
          echo "--- Actor ---"
          curl -sf -H "Accept: application/activity+json" "https://$DOMAIN/users/${{ inputs.username }}" | jq .id || echo "Actor not yet available"
```

### 3.2 Document the workflow in AGENTS.md

- [ ] Add a section to `AGENTS.md` after the "Creating a New Account" section:

```markdown
### Alternative: Provision via GitHub Actions

Instead of running the CLI directly, use the **Provision Actor** workflow:

1. Go to **Actions** > **Provision Actor**
2. Click **Run workflow**
3. Fill in username, display name, and optional summary
4. Choose the target stage
5. Run the workflow

The workflow summary shows the SSM parameter path. Retrieve the token with the AWS CLI command shown in the summary.

Note: this overwrites the shared client-token parameter. Only one account can post at a time per environment (see Limitations).
```

### Verification

- Run the workflow with `stage` environment, a test username, and verify the actor appears in WebFinger and the actor endpoint.
- The workflow summary should show the SSM parameter path and retrieval command (the token itself is masked from logs).

---

## Task 4: CI workflow for PR tests

**File:** `.github/workflows/test.yml` (new file)

No CI currently runs on pull requests. This workflow runs the unit test suite so contributors can verify changes.

### 4.1 Create the workflow

- [ ] Create `.github/workflows/test.yml`:

```yaml
name: Test

on:
  pull_request:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read

jobs:
  test:
    runs-on: ${{ vars.RUNNER_LABELS_LINUX && fromJSON(vars.RUNNER_LABELS_LINUX) || 'ubuntu-latest' }}
    steps:
      - name: Clean workspace (self-hosted)
        if: ${{ vars.RUNNER_LABELS_LINUX }}
        run: |
          sudo rm -rf .build/
          sudo git clean -fdx -e .git || true

      - name: Checkout
        uses: actions/checkout@v6
        with:
          clean: false

      - name: Install Swift
        run: |
          if swift --version 2>/dev/null | grep -q "6.3"; then
            echo "Swift 6.3 already installed"
          else
            ARCH=$(uname -m)
            if [ "$ARCH" = "aarch64" ]; then
              SWIFT_URL="https://download.swift.org/swift-6.3-release/ubuntu2404-aarch64/swift-6.3-RELEASE/swift-6.3-RELEASE-ubuntu24.04-aarch64.tar.gz"
            else
              SWIFT_URL="https://download.swift.org/swift-6.3-release/ubuntu2404/swift-6.3-RELEASE/swift-6.3-RELEASE-ubuntu24.04.tar.gz"
            fi
            curl -fsSL "$SWIFT_URL" | sudo tar xz --strip-components=2 -C /usr/local
          fi
          swift --version

      - name: Run unit tests
        run: swift test --filter ActivityPubCoreTests

      - name: Run integration tests (non-network)
        run: swift test --filter IntegrationTests
        continue-on-error: true
```

### Verification

- Open a test PR and confirm the workflow triggers.
- Verify `swift test --filter ActivityPubCoreTests` passes.

---

## Task 5: DNS setup documentation

**File:** `Sources/ActivityPubCore/Documentation.docc/DNSSetup.md` (new file)

A standalone markdown document covering both DNS modes. Referenced from the "Deploy Your Own" guide (Task 6) and from `README.md`.

### 5.1 Create the document

- [ ] Create `Sources/ActivityPubCore/Documentation.docc/DNSSetup.md` with the following content:

```markdown
# DNS Setup

This project supports two DNS architectures. Choose one before deploying.

## Simple Mode (Recommended)

**Your domain points directly to the ActivityPub server.**

- Handle: `@user@example.com`
- Server: `https://example.com`
- WebFinger: served directly at `example.com/.well-known/webfinger`
- Profile pages: served directly at `example.com/@user`

This is the default. One domain, one CloudFront distribution, one hosted zone.

### Setup

1. Deploy the bootstrap stack with `DnsMode=simple` and `DomainName=example.com`
2. The stack outputs four NS records
3. Go to your domain registrar and set the nameservers to these four values
4. Wait for DNS propagation (can take up to 48 hours, usually minutes)
5. Deploy the environment and app stacks
6. Set `ServerDomain=example.com` and `HandleDomain=example.com` in your app workflow

### Diagram

```
Browser/Fediverse
    |
    v
example.com (Route 53 -> CloudFront -> API Gateway -> Lambda)
```

## Split Mode (Advanced)

**Your handle domain is different from your server domain.**

- Handle: `@user@example.com`
- Server: `https://activity.example.com`
- WebFinger: must be proxied from `example.com/.well-known/webfinger` to `activity.example.com`
- Profile pages: `example.com/@user` must rewrite/redirect to `activity.example.com/profile/user`

This is what happitec.com uses. It requires additional infrastructure on the handle domain.

### Setup

1. Deploy the bootstrap stack with `DnsMode=split` and `DomainName=activity.example.com`
2. The stack outputs four NS records
3. In your **parent zone** (`example.com`), add an NS record delegating `activity.example.com` to these nameservers
4. Wait for DNS propagation
5. Deploy the environment and app stacks
6. Set `ServerDomain=activity.example.com` and `HandleDomain=example.com`

### Additional infrastructure on the handle domain

You need to serve these on `example.com`:

**WebFinger redirect** (`example.com/.well-known/webfinger`):

A CloudFront Function, Lambda@Edge, or reverse proxy that forwards WebFinger
requests to the server domain:

```javascript
// CloudFront Function example
function handler(event) {
    var request = event.request;
    if (request.uri === '/.well-known/webfinger') {
        return {
            statusCode: 302,
            statusDescription: 'Found',
            headers: {
                'location': {
                    value: 'https://activity.example.com/.well-known/webfinger?' +
                           Object.keys(request.querystring)
                               .map(k => k + '=' + request.querystring[k].value)
                               .join('&')
                }
            }
        };
    }
    return request;
}
```

**Profile page redirect** (`example.com/@user`):

A CloudFront Function or equivalent that redirects `/@username` paths:

```javascript
// CloudFront Function example
function handler(event) {
    var request = event.request;
    var match = request.uri.match(/^\/@([a-zA-Z0-9_]+)$/);
    if (match) {
        return {
            statusCode: 302,
            statusDescription: 'Found',
            headers: {
                'location': {
                    value: 'https://activity.example.com/profile/' + match[1]
                }
            }
        };
    }
    return request;
}
```

**Cross-distribution cache invalidation** (optional):

If you set `PROXY_DISTRIBUTION_ID` to the CloudFront distribution ID of your handle domain's CDN, the PostHandler and ProfileUpdateHandler will invalidate cached paths on that distribution when new content is published.

### Diagram

```
Browser/Fediverse
    |
    +---> example.com (handle domain)
    |         |
    |         +-- /.well-known/webfinger -> 302 -> activity.example.com
    |         +-- /@user -> 302 -> activity.example.com/profile/user
    |
    +---> activity.example.com (server domain)
              |
              +-- Route 53 -> CloudFront -> API Gateway -> Lambda
```

## Important: Handle domain is permanent

Once you federate (i.e., another server discovers your actor via WebFinger), your handle domain is baked into every remote server's database. Changing it later means:

- Existing followers see a broken account
- Links to your posts from other servers break
- You cannot migrate followers to a new domain (ActivityPub has no domain migration standard)

Choose carefully. Simple mode with your primary domain is the safest default.
```

### 5.2 Link from README.md

- [ ] Add a link in the README.md "Documentation" section:

```markdown
See [Sources/ActivityPubCore/Documentation.docc/DNSSetup.md](Sources/ActivityPubCore/Documentation.docc/DNSSetup.md) for DNS architecture options (simple vs. split domain).
```

### Verification

- The document renders correctly in GitHub markdown preview.
- Both modes are clearly explained with concrete examples.

---

## Task 6: "Deploy Your Own" guide

**File:** `Sources/ActivityPubCore/Documentation.docc/DeployYourOwn.md` (new file)

End-to-end walkthrough for an external deployer. References the DNS setup doc (Task 5) rather than duplicating it.

### 6.1 Create the guide

- [ ] Create `Sources/ActivityPubCore/Documentation.docc/DeployYourOwn.md` with the following content:

```markdown
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
| `RUNNER_LABELS_LINUX` | JSON array of runner labels (e.g. `["self-hosted", "linux"]`) | No (defaults to `ubuntu-latest`) |
| `PROXY_DISTRIBUTION_ID` | CloudFront distribution ID for cross-invalidation | No (only for split DNS) |

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

The app stack deploys all Lambda functions, API Gateway, and CloudFront.

1. Go to **Actions > Deploy App Stack**
2. Click **Run workflow**
3. Choose `stage`
4. Run the workflow

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

1. Re-run the environment workflow with `prod`
2. Re-run the app workflow with `prod`
3. Re-provision your actor with `--stage prod`
4. Or: create a GitHub release with a `v`-prefixed tag (e.g. `v1.0.0`) to trigger a prod deploy automatically

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
```

### 6.2 Link from README.md

- [ ] Add a line in the README.md after the "Documentation" section, or within it:

```markdown
See [Sources/ActivityPubCore/Documentation.docc/DeployYourOwn.md](Sources/ActivityPubCore/Documentation.docc/DeployYourOwn.md) for a step-by-step guide to deploying your own instance.
```

### Verification

- Follow the guide on a clean AWS account with a test domain and verify each step works.

---

## Task 7: Provisioner documentation update

**File:** `AGENTS.md`

### 7.1 Add local provisioning with AWS_PROFILE

- [ ] Add a section to `AGENTS.md` under "Creating a New Account":

```markdown
### Running locally with AWS credentials

If you do not have a self-hosted runner, you can run ActivityProvisioner on any machine with Swift 6.3 and AWS credentials:

```bash
# Using an AWS profile
AWS_PROFILE=myprofile swift run ActivityProvisioner \
  --stage prod \
  --username myapp \
  --display-name "My App" \
  --server-domain example.com \
  --handle-domain example.com

# Using environment variables
AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_DEFAULT_REGION=us-east-1 \
  swift run ActivityProvisioner \
  --stage prod \
  --username myapp \
  --display-name "My App" \
  --server-domain example.com \
  --handle-domain example.com
```

Requirements: Swift 6.3 (macOS or Linux), network access to AWS APIs.
```

### Verification

- The documentation is accurate and includes both credential methods.

---

## Implementation Order

Tasks should be implemented in this order due to dependencies:

1. **Task 1** (bootstrap template) -- no dependencies
2. **Task 2** (app template) -- no dependencies, can be parallel with Task 1
3. **Task 4** (CI tests) -- no dependencies, can be parallel with Tasks 1-2
4. **Task 3** (provisioning workflow) -- depends on Tasks 1-2 for variable names
5. **Task 5** (DNS docs) -- depends on Tasks 1-2 for accurate parameter names
6. **Task 7** (provisioner docs) -- no strict dependency but logically after Task 3
7. **Task 6** (deploy guide) -- depends on all other tasks; references everything

## Files Modified (Summary)

| File | Action |
|------|--------|
| `activity-bootstrap/template.yaml` | Add `DnsMode` parameter, update output descriptions |
| `activity-bootstrap/samconfig.toml` | Add `DnsMode` to parameter overrides |
| `.github/workflows/bootstrap.yml` | Add `domain-name` and `dns-mode` inputs, pass to deploy |
| `activity-app/template.yaml` | Add conditions, replace hardcoded domains, conditional IAM |
| `.github/workflows/app.yml` | Use `SERVER_DOMAIN`/`HANDLE_DOMAIN` variables |
| `.github/workflows/provision-actor.yml` | New file |
| `.github/workflows/test.yml` | New file |
| `Sources/ActivityPubCore/Documentation.docc/DNSSetup.md` | New file |
| `Sources/ActivityPubCore/Documentation.docc/DeployYourOwn.md` | New file |
| `AGENTS.md` | Add GitHub Actions and local provisioning sections |
| `README.md` | Add links to new docs, new repository variables |

## Related Issues

- #99 -- Original portability audit
- #103 -- Phase 2 tracking
- #81 -- Per-account bearer tokens (not addressed here; documented as limitation)
