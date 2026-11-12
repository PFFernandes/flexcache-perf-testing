# Test bench -> Amazon CloudWatch, for one side (origin or cache): lets that side's EC2 client
# push its test metrics to CloudWatch after each test (bench-results-sync). The VPC has no
# internet, so it needs a CloudWatch ("monitoring") interface endpoint.
#
# Resources:
#   aws_security_group.endpoint + rule      HTTPS from the VPC
#   aws_vpc_endpoint.monitoring             com.amazonaws.<region>.monitoring, private DNS
#   aws_iam_role_policy.put_metrics         PutMetricData, only in var.namespace
#
# Tags: Name = <var.name>-..., plus the Creator tag from the provider default_tags.

data "aws_region" "current" {}

resource "aws_security_group" "endpoint" {
  name        = "${var.name}-monitoring-endpoint-sg"
  description = "CloudWatch endpoint ${var.name}: HTTPS from the VPC (test bench metrics)"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-monitoring-endpoint-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.endpoint.id
  description       = "HTTPS from the VPC (EC2 client)"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443

  tags = { Name = "${var.name}-monitoring-ingress-https" }
}

resource "aws_vpc_endpoint" "monitoring" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.monitoring"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [var.subnet_id]
  security_group_ids  = [aws_security_group.endpoint.id]
  private_dns_enabled = true

  tags = { Name = "${var.name}-monitoring-endpoint" }
}

resource "aws_iam_role_policy" "put_metrics" {
  name = "${var.name}-put-bench-metrics"
  role = var.client_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "PutBenchMetrics"
      Effect   = "Allow"
      Action   = "cloudwatch:PutMetricData"
      Resource = "*" # PutMetricData has no resource ARN; the namespace condition limits it
      Condition = {
        StringEquals = { "cloudwatch:namespace" = var.namespace }
      }
    }]
  })
}
