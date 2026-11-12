# 10-bench-store

One S3 bucket that **delivers packages** to the test bench clients, in one region. The clients have
no internet, only the S3 gateway endpoint of their own region, so software they need (today the
OpenTelemetry Collector) is copied here by stack 05 and downloaded by the clients.

**No results are stored here.** Telemetry and dataset records go to the results volume
(`modules/12-bench-results-volume`).

Called by `stacks/00-bench-store` for the origin region and, when `cache_region` differs, for the
cache region.

| Resource | Setting |
|---|---|
| `aws_s3_bucket.this` | `force_destroy = false`: empty it first to delete it |
| ownership controls | `BucketOwnerEnforced` (no ACLs) |
| public access block | all four on |
| encryption | SSE-S3 (`AES256`) |
| versioning | on |
| lifecycle | old versions expire after `noncurrent_version_days` (30); unfinished multipart uploads after 7 days |

Content:

```
vendor/otelcol-contrib/<version>/otelcol-contrib_<version>_linux_<arch>.rpm
```

The clients may only read `vendor/*` (policy in `modules/11-bench-telemetry`).

| Variable | Default | |
|---|---|---|
| `bucket_name` | – | `<creator>-<project>-bench-<account>-<region>` from stack 00 |
| `noncurrent_version_days` | `30` | how long an overwritten or deleted object stays recoverable |

Outputs: `bucket`, `arn`, `region`.
