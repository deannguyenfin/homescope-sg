###############################################################################
# Observability: log groups, alarms -> SNS, and an operations dashboard.
###############################################################################

resource "aws_cloudwatch_log_group" "this" {
  for_each          = toset(["iis", "platform", "windows"])
  name              = "${var.log_group_prefix}/${each.key}"
  retention_in_days = var.log_retention_days
}

resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  for_each  = toset(var.alert_emails)
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

locals {
  frontend_alarms = toset(["alb-5xx", "alb-latency", "unhealthy-hosts", "frontend-memory"])
  all_alarms = {
    alb-5xx = {
      namespace = "AWS/ApplicationELB", metric = "HTTPCode_Target_5XX_Count", stat = "Sum"
      threshold = 20, op = "GreaterThanThreshold", periods = 2
      dims      = { LoadBalancer = var.alb_arn_suffix }
      desc      = "Front-ends returning 5xx"
    }
    alb-latency = {
      namespace = "AWS/ApplicationELB", metric = "TargetResponseTime", stat = "p95"
      threshold = 3, op = "GreaterThanThreshold", periods = 3
      dims      = { LoadBalancer = var.alb_arn_suffix }
      desc      = "p95 response time above 3s"
    }
    unhealthy-hosts = {
      namespace = "AWS/ApplicationELB", metric = "UnHealthyHostCount", stat = "Maximum"
      threshold = 0, op = "GreaterThanThreshold", periods = 3
      dims      = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
      desc      = "Unhealthy front-end in target group"
    }
    rds-cpu = {
      namespace = "AWS/RDS", metric = "CPUUtilization", stat = "Average"
      threshold = 80, op = "GreaterThanThreshold", periods = 3
      dims      = { DBInstanceIdentifier = var.db_instance_id }
      desc      = "SQL Server CPU above 80%"
    }
    rds-storage = {
      namespace = "AWS/RDS", metric = "FreeStorageSpace", stat = "Minimum"
      threshold = 10737418240, op = "LessThanThreshold", periods = 1
      dims      = { DBInstanceIdentifier = var.db_instance_id }
      desc      = "Less than 10 GB free on SQL Server"
    }
    controller-status = {
      namespace = "AWS/EC2", metric = "StatusCheckFailed", stat = "Maximum"
      threshold = 0, op = "GreaterThanThreshold", periods = 2
      dims      = { InstanceId = var.controller_instance_id }
      desc      = "Deployment Controller failed status check (deploys + timers stop)"
    }
    controller-memory = {
      namespace = "HomeScope/OutSystems", metric = "Memory % Committed Bytes In Use", stat = "Average"
      threshold = 90, op = "GreaterThanThreshold", periods = 3
      dims      = { InstanceId = var.controller_instance_id }
      desc      = "Controller committed memory above 90%"
    }
    frontend-memory = {
      namespace = "HomeScope/OutSystems", metric = "Memory % Committed Bytes In Use", stat = "Average"
      threshold = 90, op = "GreaterThanThreshold", periods = 3
      dims      = { AutoScalingGroupName = var.frontend_asg_name }
      desc      = "Front-end farm committed memory above 90% (scale-out is CPU-based)"
    }
  }
  # The LifeTime environment has no front-ends and no public traffic: skip the farm alarms there.
  alarms = { for k, v in local.all_alarms : k => v if var.has_frontends || !contains(local.frontend_alarms, k) }
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each            = local.alarms
  alarm_name          = "${var.name}-${each.key}"
  alarm_description   = each.value.desc
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  statistic           = startswith(each.value.stat, "p") ? null : each.value.stat
  extended_statistic  = startswith(each.value.stat, "p") ? each.value.stat : null
  dimensions          = each.value.dims
  period              = 300
  evaluation_periods  = each.value.periods
  threshold           = each.value.threshold
  comparison_operator = each.value.op
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# Auto-recover the controller on underlying host failure.
resource "aws_cloudwatch_metric_alarm" "controller_recover" {
  alarm_name          = "${var.name}-controller-recover"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Maximum"
  dimensions          = { InstanceId = var.controller_instance_id }
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = ["arn:aws:automate:${var.region}:ec2:recover", aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_dashboard" "ops" {
  dashboard_name = "${var.name}-ops"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title = "Requests and 5xx", region = var.region, stat = "Sum", period = 300
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix],
            [".", "HTTPCode_Target_5XX_Count", ".", "."]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title   = "Response time p95 (s)", region = var.region, stat = "p95", period = 300
          metrics = [["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix]]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title   = "Front-end CPU", region = var.region, stat = "Average", period = 300
          metrics = [["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", var.frontend_asg_name]]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title = "SQL Server", region = var.region, stat = "Average", period = 300
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.db_instance_id],
            [".", "DatabaseConnections", ".", "."]
          ]
        }
      }
    ]
  })
}
