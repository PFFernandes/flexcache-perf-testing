output "dashboard_name" {
  value = aws_cloudwatch_dashboard.this.dashboard_name
}

output "url" {
  value = "https://${data.aws_region.current.region}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.this.dashboard_name}"
}
