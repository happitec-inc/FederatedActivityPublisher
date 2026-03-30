# AWS Permissions

Minimum IAM permissions required to deploy and operate the ActivityPub server.

## Overview

Deployment uses AWS SAM (CloudFormation under the hood). The deploying principal needs permissions to create and manage all resources across the three stacks. This guide lists the minimum permissions by service.

### SAM / CloudFormation

The SAM CLI creates and updates CloudFormation stacks. The deploying IAM principal needs:

- `cloudformation:CreateStack`, `cloudformation:UpdateStack`, `cloudformation:DeleteStack`
- `cloudformation:DescribeStacks`, `cloudformation:DescribeStackEvents`, `cloudformation:DescribeStackResources`
- `cloudformation:GetTemplate`, `cloudformation:ValidateTemplate`
- `cloudformation:CreateChangeSet`, `cloudformation:ExecuteChangeSet`, `cloudformation:DescribeChangeSet`, `cloudformation:DeleteChangeSet`
- `cloudformation:ListExports` (for cross-stack references)

### Lambda

- `lambda:CreateFunction`, `lambda:UpdateFunctionCode`, `lambda:UpdateFunctionConfiguration`
- `lambda:DeleteFunction`, `lambda:GetFunction`, `lambda:ListFunctions`
- `lambda:AddPermission`, `lambda:RemovePermission`
- `lambda:CreateEventSourceMapping`, `lambda:DeleteEventSourceMapping` (for SQS trigger on deliver Lambda)
- `lambda:PutFunctionConcurrency` (for ReservedConcurrentExecutions on inbox/deliver)

### API Gateway

- `apigateway:*` on the REST API resources (SAM manages two API Gateways: federation and client)

### S3

- `s3:CreateBucket`, `s3:DeleteBucket`, `s3:PutBucketPolicy`, `s3:GetBucketPolicy`
- `s3:PutBucketPublicAccessBlock`
- `s3:PutLifecycleConfiguration`
- `s3:PutObject` to the SAM deployment bucket (for uploading Lambda zip artifacts)

### IAM

- `iam:CreateRole`, `iam:DeleteRole`, `iam:AttachRolePolicy`, `iam:DetachRolePolicy`
- `iam:PutRolePolicy`, `iam:DeleteRolePolicy`, `iam:GetRole`, `iam:PassRole`
- These are needed for SAM to create Lambda execution roles with the correct policies

### SSM Parameter Store

- `ssm:PutParameter` (for creating actor keypairs and client tokens)
- `ssm:GetParameter` (Lambda runtime reads private keys and tokens)
- `ssm:DeleteParameter` (for decommissioning actors)
- `kms:Decrypt` on `alias/aws/ssm` (SecureString parameters are KMS-encrypted)

### CloudFront

- `cloudfront:CreateDistribution`, `cloudfront:UpdateDistribution`, `cloudfront:DeleteDistribution`
- `cloudfront:GetDistribution`, `cloudfront:GetDistributionConfig`
- `cloudfront:CreateInvalidation` (used at runtime by post/profile-update Lambdas)
- `cloudfront:CreateCachePolicy`, `cloudfront:DeleteCachePolicy`
- `cloudfront:CreateOriginRequestPolicy`, `cloudfront:DeleteOriginRequestPolicy`
- `cloudfront:CreateOriginAccessControl`, `cloudfront:DeleteOriginAccessControl`

### DynamoDB

- `dynamodb:CreateTable`, `dynamodb:DeleteTable`, `dynamodb:DescribeTable`, `dynamodb:UpdateTable`
- `dynamodb:UpdateContinuousBackups` (for enabling PITR on prod)
- At runtime, Lambda roles need: `dynamodb:GetItem`, `dynamodb:PutItem`, `dynamodb:UpdateItem`, `dynamodb:DeleteItem`, `dynamodb:Query`

### SQS

- `sqs:CreateQueue`, `sqs:DeleteQueue`, `sqs:GetQueueAttributes`, `sqs:SetQueueAttributes`
- At runtime: `sqs:SendMessage`, `sqs:SendMessageBatch`, `sqs:ReceiveMessage`, `sqs:DeleteMessage`

### Route 53

- `route53:CreateHostedZone`, `route53:GetHostedZone`
- `route53:ChangeResourceRecordSets` (for creating A/AAAA alias records pointing to CloudFront)
- `route53:ListResourceRecordSets`

### ACM (Certificate Manager)

- `acm:RequestCertificate`, `acm:DescribeCertificate`, `acm:DeleteCertificate`
- `acm:AddTagsToCertificate`
- The certificate must be in `us-east-1` for CloudFront to use it

### CloudWatch (Optional but Recommended)

- `cloudwatch:PutMetricAlarm`, `cloudwatch:DeleteAlarms` (for DLQ monitoring)
- `logs:CreateLogGroup`, `logs:PutRetentionPolicy` (Lambda automatically creates log groups)
- `sns:CreateTopic`, `sns:Subscribe` (for DLQ alarm notifications)
