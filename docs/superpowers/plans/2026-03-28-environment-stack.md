# Environment Stack Implementation Plan

**Goal:** Create the `activity-environment` SAM template and GitHub Actions workflow. The template defines per-environment data stores (DynamoDB, S3, SQS) parameterized by `Stage`. Deployed manually for prod and stage.

**Architecture:** Single SAM template reused across environments via the `Stage` parameter. Resources have `DeletionPolicy: Retain` since they hold persistent data. Imports bootstrap stack exports. Exports resource names/ARNs for the app stack.

**Tech Stack:** AWS SAM, CloudFormation, DynamoDB, S3, SQS, CloudWatch

---

### Task 1: Create the SAM template

**Files:**
- Create: `activity-environment/template.yaml`

- [ ] **Step 1: Create the directory**

```bash
mkdir -p activity-environment
```

- [ ] **Step 2: Write the SAM template**

```yaml
AWSTemplateFormatVersion: "2010-09-09"
Transform: AWS::Serverless-2016-10-31
Description: >
  activity-environment — per-environment data layer.
  Long-lived data stores and queues. Prod and stage each get their own stack.
  You can redeploy the app stack without touching data.

Parameters:
  Stage:
    Type: String
    AllowedValues:
      - prod
      - stage
    Description: Environment name (prod or stage)
  BootstrapStackName:
    Type: String
    Default: activity-bootstrap
    Description: Name of the bootstrap stack to import from

Conditions:
  IsProd: !Equals [!Ref Stage, prod]

Resources:
  MediaBucket:
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Sub "activity-media-${Stage}"
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault:
              SSEAlgorithm: AES256
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      LifecycleConfiguration:
        Rules:
          - Id: AbortIncompleteMultipartUploads
            Status: Enabled
            AbortIncompleteMultipartUpload:
              DaysAfterInitiation: 7

  ActorsTable:
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Type: AWS::DynamoDB::Table
    Properties:
      TableName: !Sub "activity-${Stage}"
      BillingMode: PAY_PER_REQUEST
      PointInTimeRecoverySpecification:
        PointInTimeRecoveryEnabled: !If [IsProd, true, false]
      TimeToLiveSpecification:
        AttributeName: ttl
        Enabled: true
      AttributeDefinitions:
        - AttributeName: PK
          AttributeType: S
        - AttributeName: SK
          AttributeType: S
        - AttributeName: GSI1PK
          AttributeType: S
        - AttributeName: GSI1SK
          AttributeType: S
      KeySchema:
        - AttributeName: PK
          KeyType: HASH
        - AttributeName: SK
          KeyType: RANGE
      GlobalSecondaryIndexes:
        - IndexName: GSI1
          KeySchema:
            - AttributeName: GSI1PK
              KeyType: HASH
            - AttributeName: GSI1SK
              KeyType: RANGE
          Projection:
            ProjectionType: ALL

  DeliveryQueue:
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Type: AWS::SQS::Queue
    Properties:
      QueueName: !Sub "activity-delivery-${Stage}"
      VisibilityTimeout: 120
      RedrivePolicy:
        deadLetterTargetArn: !GetAtt DeliveryDLQ.Arn
        maxReceiveCount: 3

  DeliveryDLQ:
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Type: AWS::SQS::Queue
    Properties:
      QueueName: !Sub "activity-delivery-dlq-${Stage}"

  DLQAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub "activity-dlq-depth-${Stage}"
      AlarmDescription: !Sub "Messages in activity delivery DLQ (${Stage})"
      Namespace: AWS/SQS
      MetricName: ApproximateNumberOfMessagesVisible
      Dimensions:
        - Name: QueueName
          Value: !GetAtt DeliveryDLQ.QueueName
      Statistic: Maximum
      Period: 60
      EvaluationPeriods: 1
      Threshold: 0
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching

Outputs:
  MediaBucketName:
    Description: S3 media bucket name
    Value: !Ref MediaBucket
    Export:
      Name: !Sub "${AWS::StackName}-MediaBucketName"

  MediaBucketArn:
    Description: S3 media bucket ARN
    Value: !GetAtt MediaBucket.Arn
    Export:
      Name: !Sub "${AWS::StackName}-MediaBucketArn"

  TableName:
    Description: DynamoDB table name
    Value: !Ref ActorsTable
    Export:
      Name: !Sub "${AWS::StackName}-TableName"

  TableArn:
    Description: DynamoDB table ARN
    Value: !GetAtt ActorsTable.Arn
    Export:
      Name: !Sub "${AWS::StackName}-TableArn"

  QueueUrl:
    Description: SQS delivery queue URL
    Value: !Ref DeliveryQueue
    Export:
      Name: !Sub "${AWS::StackName}-QueueUrl"

  QueueArn:
    Description: SQS delivery queue ARN
    Value: !GetAtt DeliveryQueue.Arn
    Export:
      Name: !Sub "${AWS::StackName}-QueueArn"

  SSMKeyPrefix:
    Description: SSM Parameter Store prefix for actor keys
    Value: !Sub "/activity/${Stage}/keys/"
    Export:
      Name: !Sub "${AWS::StackName}-SSMKeyPrefix"
```

- [ ] **Step 3: Validate the template locally**

Run: `sam validate --template-file activity-environment/template.yaml`
Expected: Template is valid

- [ ] **Step 4: Commit**

```bash
git add activity-environment/template.yaml
git commit -m "Add activity-environment SAM template

DynamoDB (single-table, on-demand, PITR for prod), S3 media bucket
(private, AES256, lifecycle rules), SQS delivery queue + DLQ with
CloudWatch alarm. Parameterized by Stage."
```

### Task 2: Create the SAM config

**Files:**
- Create: `activity-environment/samconfig.toml`

- [ ] **Step 1: Write the samconfig.toml**

```toml
version = 0.1

[default.global.parameters]
stack_name = "activity-environment-stage"

[default.deploy.parameters]
capabilities = "CAPABILITY_IAM"
confirm_changeset = true
region = "us-east-1"
parameter_overrides = "Stage=stage BootstrapStackName=activity-bootstrap"
```

- [ ] **Step 2: Commit**

```bash
git add activity-environment/samconfig.toml
git commit -m "Add samconfig.toml for environment stack (stage default)"
```

### Task 3: Create the GitHub Actions workflow

**Files:**
- Create: `.github/workflows/environment.yml`

- [ ] **Step 1: Write the workflow**

```yaml
name: Deploy Environment Stack

permissions:
  contents: read

on:
  workflow_dispatch:
    inputs:
      stage:
        description: "Environment to deploy (prod or stage)"
        required: true
        type: choice
        options:
          - stage
          - prod

jobs:
  deploy:
    runs-on: [self-hosted, linux]
    steps:
      - name: Checkout code
        uses: actions/checkout@v6

      - name: Install SAM CLI
        uses: happitec-inc/happitec-logo-generator/.github/actions/setup-sam-portable@main
        with:
          token: ${{ secrets.GITHUB_TOKEN }}

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v6
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: us-east-1

      - name: SAM build
        run: sam build --template-file activity-environment/template.yaml

      - name: SAM deploy
        run: |
          sam deploy \
            --template-file .aws-sam/build/template.yaml \
            --stack-name "activity-environment-${{ inputs.stage }}" \
            --capabilities CAPABILITY_IAM \
            --no-confirm-changeset \
            --no-fail-on-empty-changeset \
            --region us-east-1 \
            --parameter-overrides \
              Stage=${{ inputs.stage }} \
              BootstrapStackName=activity-bootstrap

      - name: Print stack outputs
        run: |
          echo "## Stack Outputs" >> $GITHUB_STEP_SUMMARY
          aws cloudformation describe-stacks \
            --stack-name "activity-environment-${{ inputs.stage }}" \
            --query "Stacks[0].Outputs[].[OutputKey, OutputValue]" \
            --output table \
            --region us-east-1 >> $GITHUB_STEP_SUMMARY
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/environment.yml
git commit -m "Add GitHub Actions workflow for environment stack

Manual dispatch with stage selector (prod or stage).
Self-hosted Linux runner, setup-sam-portable."
```

### Task 4: Push and open PR

- [ ] **Step 1: Push branch and open PR**

### Post-deploy (manual)

After the workflow runs successfully for stage:
1. Verify stack outputs in the job summary (MediaBucketName, TableName, QueueUrl, etc.)
2. Verify DynamoDB table exists with correct key schema and GSI1
3. Verify S3 bucket has public access blocked
4. Verify SQS queue and DLQ are created with correct visibility timeout
