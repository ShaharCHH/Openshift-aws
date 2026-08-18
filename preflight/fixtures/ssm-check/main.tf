# The SSM agent needs 30-90s after boot to register, so probe.sh polls
# describe-instance-information + send-command/get-command-invocation with
# retries rather than checking once — a single-shot check would be flaky
# and produce false negatives unrelated to real capability.

data "external" "ssm_probe" {
  program = ["${path.module}/probe.sh", var.instance_id, tostring(var.timeout_seconds)]
}
