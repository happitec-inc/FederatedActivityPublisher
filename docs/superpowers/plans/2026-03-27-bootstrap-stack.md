# Bootstrap Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy the `activity-bootstrap` SAM stack — a Route 53 hosted zone and ACM wildcard certificate for `activity.happitec.com` — and validate that DNS delegation works.

**Architecture:** Single CloudFormation/SAM template with two resources (hosted zone + cert). Deployed once, manually. All other stacks depend on its exports (`HostedZoneId`, `CertificateArn`). The parent `happitec.com` zone requires an NS delegation record pointing to this hosted zone.

**Tech Stack:** AWS SAM CLI, CloudFormation, Route 53, ACM

---

### Task 1: Create the SAM template

**Files:**
- Create: `activity-bootstrap/template.yaml`

- [ ] **Step 1: Create the directory**

```bash
mkdir -p activity-bootstrap
```

- [ ] **Step 2: Write the SAM template**

```yaml
AWSTemplateFormatVersion: "2010-09-09"
Transform: AWS::Serverless-2016-10-31
Description: >
  activity-bootstrap — shared resources that outlive all environments.
  Route 53 hosted zone and ACM wildcard certificate for activity.happitec.com.
  Deployed once, manually. All other stacks import these exports.

Parameters:
  DomainName:
    Type: String
    Default: activity.happitec.com
    Description: Base domain for the ActivityPub server

Resources:
  HostedZone:
    Type: AWS::Route53::HostedZone
    Properties:
      Name: !Ref DomainName
      HostedZoneConfig:
        Comment: !Sub "ActivityPub server zone for ${DomainName}"

  WildcardCertificate:
    Type: AWS::CertificateManager::Certificate
    Properties:
      DomainName: !Ref DomainName
      SubjectAlternativeNames:
        - !Sub "*.${DomainName}"
      ValidationMethod: DNS
      DomainValidationOptions:
        - DomainName: !Ref DomainName
          HostedZoneId: !Ref HostedZone
        - DomainName: !Sub "*.${DomainName}"
          HostedZoneId: !Ref HostedZone

Outputs:
  HostedZoneId:
    Description: Route 53 hosted zone ID for activity.happitec.com
    Value: !Ref HostedZone
    Export:
      Name: !Sub "${AWS::StackName}-HostedZoneId"

  CertificateArn:
    Description: ACM wildcard certificate ARN (activity.happitec.com + *.activity.happitec.com)
    Value: !Ref WildcardCertificate
    Export:
      Name: !Sub "${AWS::StackName}-CertificateArn"

  NameServers:
    Description: NS records to add to the parent happitec.com zone
    Value: !Join
      - ", "
      - !GetAtt HostedZone.NameServers
```

- [ ] **Step 3: Validate the template locally**

Run: `cd /Users/spar/web-local/activity.happitec.com && sam validate --template-file activity-bootstrap/template.yaml`
Expected: Template is valid

- [ ] **Step 4: Commit**

```bash
git add activity-bootstrap/template.yaml
git commit -m "Add activity-bootstrap SAM template

Route 53 hosted zone + ACM wildcard certificate for
activity.happitec.com. Exports HostedZoneId, CertificateArn,
and NameServers for downstream stacks."
```

### Task 2: Create the SAM config for bootstrap

**Files:**
- Create: `activity-bootstrap/samconfig.toml`

- [ ] **Step 1: Write the samconfig.toml**

```toml
version = 0.1

[default.global.parameters]
stack_name = "activity-bootstrap"

[default.deploy.parameters]
capabilities = "CAPABILITY_IAM"
confirm_changeset = true
region = "us-east-1"
```

Note: `us-east-1` is required for ACM certificates used with CloudFront. The certificate must be in `us-east-1` regardless of where other resources are deployed.

- [ ] **Step 2: Commit**

```bash
git add activity-bootstrap/samconfig.toml
git commit -m "Add samconfig.toml for bootstrap stack

Targets us-east-1 (required for ACM + CloudFront)."
```

### Task 3: Deploy the bootstrap stack

- [ ] **Step 1: Deploy**

Run from the repo root:
```bash
cd /Users/spar/web-local/activity.happitec.com && sam deploy --template-file activity-bootstrap/template.yaml --config-file activity-bootstrap/samconfig.toml
```

SAM will show a changeset with:
- `AWS::Route53::HostedZone` — CREATE
- `AWS::CertificateManager::Certificate` — CREATE

Review the changeset and confirm. **Important:** The ACM certificate will initially be in `PENDING_VALIDATION` status. CloudFormation will wait for DNS validation to succeed before completing. Since the certificate's `DomainValidationOptions` references the hosted zone being created in the same template, CloudFormation should auto-create the DNS validation CNAME records in Route 53. The stack creation may take 5-15 minutes while waiting for ACM validation to propagate.

- [ ] **Step 2: Verify the stack outputs**

```bash
aws cloudformation describe-stacks --stack-name activity-bootstrap --query "Stacks[0].Outputs" --output table --region us-east-1
```

Expected: Three outputs — `HostedZoneId`, `CertificateArn`, `NameServers`. Record the `NameServers` values — these are needed for the parent zone delegation.

- [ ] **Step 3: Verify ACM certificate status**

```bash
aws acm describe-certificate --certificate-arn $(aws cloudformation describe-stacks --stack-name activity-bootstrap --query "Stacks[0].Outputs[?OutputKey=='CertificateArn'].OutputValue" --output text --region us-east-1) --query "Certificate.Status" --output text --region us-east-1
```

Expected: `ISSUED`

If the status is `PENDING_VALIDATION`, the NS delegation in the parent zone is not yet in place or hasn't propagated. Proceed to Task 4.

### Task 4: Add NS delegation in parent zone

This step requires adding NS records in the parent `happitec.com` zone so that DNS queries for `activity.happitec.com` are directed to the hosted zone created in Task 3.

- [ ] **Step 1: Get the name servers**

```bash
aws cloudformation describe-stacks --stack-name activity-bootstrap --query "Stacks[0].Outputs[?OutputKey=='NameServers'].OutputValue" --output text --region us-east-1
```

This will output 4 name servers (comma-separated). These NS records must be added to the `happitec.com` parent zone.

- [ ] **Step 2: Notify the user**

**STOP HERE and notify the user.** The NS delegation records must be added to the parent `happitec.com` zone. This may be managed in a different AWS account, registrar, or DNS provider. Provide the user with the 4 NS values and ask them to create an NS record set for `activity.happitec.com` in the parent zone.

Use: `notify --message "Bootstrap stack deployed. NS delegation needed in parent happitec.com zone. Check Claude Code for the NS values."`

- [ ] **Step 3: Verify DNS delegation is working**

After the user confirms NS records are in place:

```bash
dig activity.happitec.com NS +short
```

Expected: Returns the 4 name servers from the bootstrap hosted zone. If empty or returns NXDOMAIN, delegation is not yet propagated — wait and retry.

- [ ] **Step 4: Verify ACM certificate is issued**

If the certificate was `PENDING_VALIDATION` earlier, check again:

```bash
aws acm describe-certificate --certificate-arn $(aws cloudformation describe-stacks --stack-name activity-bootstrap --query "Stacks[0].Outputs[?OutputKey=='CertificateArn'].OutputValue" --output text --region us-east-1) --query "Certificate.Status" --output text --region us-east-1
```

Expected: `ISSUED`

### Task 5: Final validation and push

- [ ] **Step 1: Verify all stack exports are available for downstream stacks**

```bash
aws cloudformation list-exports --query "Exports[?starts_with(Name, 'activity-bootstrap')]" --output table --region us-east-1
```

Expected: Two exports — `activity-bootstrap-HostedZoneId` and `activity-bootstrap-CertificateArn`.

- [ ] **Step 2: Push all commits**

```bash
git push
```

- [ ] **Step 3: Notify the user**

Use: `notify --message "Bootstrap stack fully deployed and validated. DNS delegation working, ACM certificate issued. Ready for step 2 (environment stack)."`
