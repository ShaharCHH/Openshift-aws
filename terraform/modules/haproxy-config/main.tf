# Renders haproxy.cfg from the current backend lists, uploads it to S3, then
# pushes + reloads it on the bastion via SSM. Invoked repeatedly across the
# cluster lifecycle (bootstrap+masters -> masters only -> masters+workers)
# without ever replacing or rebooting the bastion instance -- see
# docs/architecture.md's "Keeping HAProxy's backend list current" section.

locals {
  rendered_cfg = templatefile("${path.module}/../../templates/haproxy.cfg.tpl", {
    api_backends     = var.api_backends
    mcs_backends     = var.mcs_backends
    ingress_backends = var.ingress_backends
  })
  config_hash = md5(local.rendered_cfg)
}

resource "aws_s3_object" "haproxy_cfg" {
  bucket  = var.bucket_name
  key     = "haproxy/haproxy.cfg"
  content = local.rendered_cfg
  etag    = local.config_hash
}

# A failed reload fails this apply, rather than silently leaving stale
# config running -- `aws ssm wait command-executed` blocks until the remote
# command finishes, and the script's own `set -e` (plus haproxy -c's config
# validation before the reload) means a bad config surfaces here, not later.
resource "null_resource" "push_and_reload" {
  triggers = {
    config_hash = local.config_hash
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      # The SSM agent needs 30-90s after boot to register -- send-command
      # against an instance that isn't "managed" yet fails with
      # InvalidInstanceId, not a retryable/transient-looking error, so this
      # has to be waited for explicitly rather than assumed.
      for i in $(seq 1 24); do
        STATE=$(aws ssm describe-instance-information --region ${var.aws_region} \
          --filters "Key=InstanceIds,Values=${var.bastion_instance_id}" \
          --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "None")
        [ "$STATE" = "Online" ] && break
        sleep 5
      done
      if [ "$STATE" != "Online" ]; then
        echo "bastion SSM agent never came online" >&2
        exit 1
      fi

      CMD_ID=$(aws ssm send-command --region ${var.aws_region} \
        --instance-ids ${var.bastion_instance_id} \
        --document-name AWS-RunShellScript \
        --parameters '{"commands":["aws s3 cp s3://${var.bucket_name}/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg --region ${var.aws_region}","docker exec haproxy haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg","docker kill --signal=HUP haproxy","echo ${local.config_hash} > /etc/haproxy/.last-etag"]}' \
        --query 'Command.CommandId' --output text)
      aws ssm wait command-executed --region ${var.aws_region} --command-id "$CMD_ID" --instance-id ${var.bastion_instance_id}
    EOT
  }

  depends_on = [aws_s3_object.haproxy_cfg]
}
