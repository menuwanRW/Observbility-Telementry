data "aws_region" "current" {}

locals {
  alarm_actions = [aws_sns_topic.alerts.arn]
  alb_dim       = { LoadBalancer = var.alb_arn_suffix }
  svc_dim       = { ClusterName = var.cluster_name, ServiceName = var.service_name }
}

# NOTE: topic is not CMK-encrypted on purpose. CloudWatch alarms cannot publish to a topic encrypted with the
# AWS-managed key, and alarm text carries no PII. Use a customer-managed key with a cloudwatch.amazonaws.com
# grant if policy requires encrypted topics.
resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ---------- Symptom alarms (user-visible, page a human) ----------
resource "aws_cloudwatch_metric_alarm" "error_ratio" {
  alarm_name          = "${var.name}-5xx-ratio"
  alarm_description   = "More than ${var.error_ratio_threshold * 100}% of requests are failing with 5xx. Check recent deploys first."
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.error_ratio_threshold
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  metric_query {
    id          = "ratio"
    label       = "5xx ratio"
    expression  = "IF(req > 20, FILL(errs, 0) / req, 0)" # ignore very low traffic where 1 error = 100%
    return_data = true
  }
  metric_query {
    id = "errs"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      period      = 60
      stat        = "Sum"
      dimensions  = local.alb_dim
    }
  }
  metric_query {
    id = "req"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      period      = 60
      stat        = "Sum"
      dimensions  = local.alb_dim
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "latency_p99" {
  alarm_name          = "${var.name}-latency-p99"
  alarm_description   = "p99 target response time above ${var.p99_latency_seconds}s"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = local.alb_dim
  extended_statistic  = "p99"
  period              = 60
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.p99_latency_seconds
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  alarm_name          = "${var.name}-unhealthy-targets"
  alarm_description   = "At least one target is failing ALB health checks"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
  statistic           = "Maximum"
  period              = 60
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  evaluation_periods  = 3
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "running_tasks" {
  alarm_name          = "${var.name}-running-tasks-low"
  alarm_description   = "Fewer running tasks than the minimum: crash loop, failed deploy, or capacity problem"
  namespace           = "ECS/ContainerInsights"
  metric_name         = "RunningTaskCount"
  dimensions          = local.svc_dim
  statistic           = "Minimum"
  period              = 60
  comparison_operator = "LessThanThreshold"
  threshold           = var.min_running_tasks
  evaluation_periods  = 3
  treat_missing_data  = "breaching" # no data at all is itself an outage signal
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# ---------- Application errors from logs (log-based metric) ----------
resource "aws_cloudwatch_log_metric_filter" "app_errors" {
  name           = "${var.name}-app-errors"
  log_group_name = var.log_group_name
  pattern        = "{ $.level = \"error\" }" # matches the app's structured JSON logs
  metric_transformation {
    name          = "AppErrorCount"
    namespace     = "${var.name}/App"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "app_errors" {
  alarm_name          = "${var.name}-app-errors"
  alarm_description   = "Application is logging errors at an elevated rate"
  namespace           = "${var.name}/App"
  metric_name         = "AppErrorCount"
  statistic           = "Sum"
  period              = 60
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 10
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  depends_on          = [aws_cloudwatch_log_metric_filter.app_errors]
}

# ---------- Cause alarms (saturation, ticket not page) ----------
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.name}-cpu-high"
  alarm_description   = "Sustained CPU above 85%: autoscaling is not keeping up or max_count is too low"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = local.svc_dim
  statistic           = "Average"
  period              = 60
  comparison_operator = "GreaterThanThreshold"
  threshold           = 85
  evaluation_periods  = 10
  datapoints_to_alarm = 8
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "memory_high" {
  alarm_name          = "${var.name}-memory-high"
  alarm_description   = "Sustained memory above 85%: possible leak, OOM kills ahead"
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  dimensions          = local.svc_dim
  statistic           = "Average"
  period              = 60
  comparison_operator = "GreaterThanThreshold"
  threshold           = 85
  evaluation_periods  = 10
  datapoints_to_alarm = 8
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

# ---------- Dashboard ----------
resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = var.name
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title = "Traffic and 5xx", region = data.aws_region.current.name, stat = "Sum", period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix],
            [".", "HTTPCode_Target_5XX_Count", ".", "."]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title = "Latency (p50 / p99)", region = data.aws_region.current.name, period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "p50" }],
            ["...", { stat = "p99" }]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title = "CPU / Memory (%)", region = data.aws_region.current.name, stat = "Average", period = 60
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", var.cluster_name, "ServiceName", var.service_name],
            [".", "MemoryUtilization", ".", ".", ".", "."]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title = "Running tasks and healthy targets", region = data.aws_region.current.name, stat = "Average", period = 60
          metrics = [
            ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", var.cluster_name, "ServiceName", var.service_name],
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.target_group_arn_suffix]
          ]
        }
      },
      {
        type = "log", x = 0, y = 12, width = 24, height = 6
        properties = {
          title  = "Recent errors", region = data.aws_region.current.name
          query  = "SOURCE '${var.log_group_name}' | fields @timestamp, msg, path, status | filter level = 'error' | sort @timestamp desc | limit 50"
          view   = "table"
        }
      }
    ]
  })
}
