# Confirms the target subnet actually has outbound internet access, over
# whatever path this account provides (NAT Gateway, centralized inspection,
# etc. -- we don't assume any specific mechanism, only that HTTPS egress
# works). This is a real, load-bearing assumption of the current design: the
# bastion pulls ignition/haproxy-config files from S3 using its own IAM role
# over this same path (see docs/architecture.md), and SSM itself requires
# reaching its own API endpoints, which every other canary in this suite
# already implicitly depends on.
data "external" "egress_probe" {
  program = ["${path.module}/probe.sh", var.instance_id, tostring(var.timeout_seconds)]
}
