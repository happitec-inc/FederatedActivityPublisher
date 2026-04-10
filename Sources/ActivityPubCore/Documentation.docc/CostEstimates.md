# Cost Estimates

Estimated monthly AWS costs at different follower counts.

## Overview

The serverless architecture means you pay only for what you use. At rest (no posts, no incoming traffic), the dominant cost is the Route 53 hosted zone at $0.50/month. All other services have generous free tiers that cover light usage.

### Cost Breakdown by Scale

| Service | 100 followers | 1,000 followers | 100,000 followers |
|---|---|---|---|
| **Route 53** (hosted zone) | $0.50 | $0.50 | $0.50 |
| **Route 53** (DNS queries) | < $0.01 | < $0.01 | $0.10 |
| **Lambda** (invocations) | < $0.01 | $0.05 | $20.00 |
| **Lambda** (compute, 512 MB) | < $0.01 | $0.10 | $35.00 |
| **DynamoDB** (reads, on-demand) | < $0.01 | $0.02 | $2.00 |
| **DynamoDB** (writes, on-demand) | < $0.01 | $0.05 | $4.00 |
| **DynamoDB** (storage) | < $0.01 | < $0.01 | $0.25 |
| **S3** (storage) | < $0.01 | < $0.01 | $0.50 |
| **S3** (requests) | < $0.01 | < $0.01 | $0.10 |
| **SQS** (messages) | < $0.01 | < $0.01 | $2.00 |
| **CloudFront** (requests) | < $0.01 | $0.10 | $2.00 |
| **CloudFront** (data transfer) | < $0.01 | $0.10 | $5.00 |
| **SSM** (parameter reads) | $0.00 | < $0.01 | $4.50 |
| **ACM** (certificate) | $0.00 | $0.00 | $0.00 |
| **Total** | **~$0.50** | **~$1-2** | **~$70-100** |

### Assumptions

These estimates assume:

- **100 followers:** 2-3 posts per week, minimal inbound traffic. Most federation reads served from CloudFront cache.
- **1,000 followers:** Daily posts, moderate inbound follows/likes/boosts. Delivery fan-out creates ~1,000 SQS messages per post.
- **100,000 followers:** Multiple posts per day, heavy inbound traffic. Each post fans out 100,000 SQS delivery jobs, each invoking the deliver Lambda individually. At 3 posts/day that is ~9M Lambda invocations/month for delivery alone. CloudFront serves the vast majority of read traffic.

### Cost Optimization Notes

- **DynamoDB on-demand billing** means zero cost when idle. No provisioned capacity to pay for.
- **CloudFront TTL-based caching** means most read requests never reach Lambda. A post with 100,000 followers creates 100,000 delivery Lambda invocations, and the outbox cache expires naturally within its TTL (1 hour) -- no invalidation API calls needed.
- **Lambda ARM64 (Graviton)** is ~20% cheaper than x86_64.
- **S3 media** has no public access -- CloudFront OAC serves files with immutable cache headers, so each media file is typically fetched from S3 only once per edge location.
- **SSM Parameter Store Standard tier** is free for storage. You pay only for `GetParameter` API calls at $0.05 per 10,000 calls. With bearer tokens now stored in DynamoDB, SSM reads are limited to keypair lookups during delivery signing and legacy token fallback.
- **ACM certificates** are free when used with CloudFront.
- **Free tier credits** (first 12 months of an AWS account) cover 1M Lambda invocations, 25 GB DynamoDB storage, 5 GB S3 storage, and more. In practice, a small ActivityPub server can run within the free tier for the first year.
