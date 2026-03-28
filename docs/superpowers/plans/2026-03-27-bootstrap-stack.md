# Bootstrap Stack Implementation Plan

**Goal:** Create the `activity-bootstrap` SAM template, GitHub Actions workflow, and samconfig — ready to deploy via CI on merge to main.

**Architecture:** Single CloudFormation/SAM template with two resources (Route 53 hosted zone + ACM wildcard cert). Deployed via GitHub Actions on a self-hosted Linux runner. All other stacks depend on its exports (`HostedZoneId`, `CertificateArn`). After deployment, NS delegation records must be added to the parent `happitec.com` zone manually.

**Tech Stack:** AWS SAM, CloudFormation, Route 53, ACM, GitHub Actions

---

## Deliverables

All deliverables are files — no local deployment commands. CI handles deployment on merge.

### Task 1: SAM template (done)

`activity-bootstrap/template.yaml` — already on this branch.

### Task 2: SAM config (done)

`activity-bootstrap/samconfig.toml` — already on this branch.

### Task 3: GitHub Actions workflow

**Files:**
- Create: `.github/workflows/bootstrap.yml`

Workflow modeled on `happitec.com/.github/workflows/infrastructure.yml`:
- Self-hosted Linux runner (`[self-hosted, linux]`)
- `setup-sam-portable` action from `happitec-inc/happitec-logo-generator`
- `aws-actions/configure-aws-credentials@v6` with secrets
- `sam build` + `sam deploy` targeting `us-east-1`
- Triggered on push to main (only when `activity-bootstrap/**` files change)
- Manual trigger (`workflow_dispatch`) for first-time deploy

### Post-deploy (manual, not CI)

After the workflow runs successfully:
1. Read the stack outputs to get the 4 NS values
2. Add NS delegation record for `activity.happitec.com` in the parent `happitec.com` zone
3. Verify DNS propagation: `dig activity.happitec.com NS +short`
4. Verify ACM certificate status is `ISSUED`
