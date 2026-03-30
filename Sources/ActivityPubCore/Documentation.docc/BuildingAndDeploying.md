# Building and Deploying

Build Lambda binaries with Docker and deploy with SAM.

## Overview

The project builds Swift Lambda binaries targeting Amazon Linux 2023 (ARM64). A custom Docker image handles cross-compilation, and SAM CLI manages packaging and CloudFormation deployment.

### Building the Docker Image

The repository includes a Dockerfile for the build environment:

```bash
docker build -t activity-builder -f docker/Dockerfile.al2023-swift .
```

This image contains Swift 6.3 on Amazon Linux 2023 and is used by the AWSLambdaPackager plugin to produce deployment-ready zip archives.

### Building Lambda Binaries

Use the Swift Package Manager's AWSLambdaPackager plugin to build all Lambda handlers:

```bash
swift package --disable-sandbox plugin \
  --allow-writing-to-package-directory \
  AWSLambdaPackager \
  --configuration release \
  --swift-version 6.3
```

This produces zip archives under `.build/plugins/AWSLambdaPackager/outputs/AWSLambdaPackager/` for each executable target.

### Deploying with SAM

Deploy the three stacks in order. The bootstrap stack is deployed once; the environment and app stacks are deployed per stage.

**Bootstrap (one-time):**

```bash
cd activity-bootstrap
sam deploy --guided --stack-name activity-bootstrap
```

After deploying, add an NS delegation record in your parent `happitec.com` hosted zone pointing to the new `activity.happitec.com` hosted zone's nameservers.

**Environment (per stage):**

```bash
cd activity-environment
sam deploy \
  --stack-name activity-environment-prod \
  --parameter-overrides Stage=prod
```

**App (per stage):**

```bash
cd activity-app
sam deploy \
  --stack-name activity-app-prod \
  --parameter-overrides Stage=prod \
    EnvironmentStackName=activity-environment-prod \
    BootstrapStackName=activity-bootstrap
```

### Self-Hosted Linux Runners

CI builds run on self-hosted Linux runners (`linux-runner`, `linux-runner-2`) provisioned with Tart VMs. These runners have Swift 6.3 and Docker pre-installed. The GitHub Actions workflows (`.github/workflows/app.yml`) handle building Lambda zips and deploying via SAM on these runners.

### CloudFront Cache Invalidation

When you deploy a new app stack version, existing CloudFront cache entries remain valid. The `PostHandler` and `ProfileUpdateHandler` Lambdas automatically issue CloudFront invalidations when content changes, so you do not need to manually invalidate the cache after deployment.
