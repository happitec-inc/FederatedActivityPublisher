# Media

How media uploads are parsed, stored, and served.

## Overview

FederatedActivityPublisher supports image, video, and audio attachments on statuses. Media files are uploaded through the client API, stored in S3, and served through CloudFront with immutable cache headers. The `ActivityPubCore` module provides the multipart parsing layer that the MediaUploadHandler Lambda depends on.

### Multipart Parsing

The client API accepts media uploads as `multipart/form-data` requests. The ``extractBoundary(from:)`` function reads the boundary string from the Content-Type header, and ``parseMultipart(data:boundary:)`` splits the request body into individual ``MultipartPart`` values, each carrying its field name, optional filename, content type, and raw data.

### Upload Flow

The MediaUploadHandler Lambda receives the multipart request, validates the content type, generates a unique media ID, writes the file to S3 using write-only IAM permissions, and records the media metadata in DynamoDB. The response includes a media ID that the client includes when creating a status.

### Storage and CDN

The S3 media bucket has no public access. All reads go through CloudFront using Origin Access Control (OAC), which means the bucket never needs a public policy. Media objects are cached with a 365-day TTL and never invalidated, since each upload gets a unique key. The CloudFront distribution serves media at `https://{your-domain}/media/`.
