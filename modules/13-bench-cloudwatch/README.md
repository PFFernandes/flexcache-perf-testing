# 13-bench-cloudwatch

Lets one side's EC2 client push its test bench metrics to Amazon CloudWatch, **after each test**
(`bench-results-sync`, see `bench/results/cloudwatch.py`). Called by `stacks/05-bench` once per
client (origin, cache) when `telemetry = true` and `cloudwatch = true`, in that client's region.

| Resource | Purpose |
|---|---|
| `aws_security_group.endpoint` + rule | HTTPS to the endpoint from the VPC |
| `aws_vpc_endpoint.monitoring` | `com.amazonaws.<region>.monitoring` interface endpoint, private DNS (the VPC has no internet) |
| `aws_iam_role_policy.put_metrics` | `cloudwatch:PutMetricData` on the client role, only in `var.namespace` (`FlexCacheBench`) |

| Variable | Default | |
|---|---|---|
| `name` | – | resource name prefix |
| `vpc_id`, `vpc_cidr`, `subnet_id` | – | the client's VPC and subnet |
| `client_role_name` | – | the client's IAM role |
| `namespace` | `FlexCacheBench` | the only namespace the client may write to |

Outputs: `endpoint_id`, `region`, `namespace`.

Cost: the interface endpoint, about USD 0.01/h, plus the custom metrics the client publishes (see
the top-level README, Costs).
