#!/bin/bash
# Bastion day-0 setup: CoreDNS + HAProxy + ignition HTTP server, all as
# --network host Docker containers (not Podman -- unavailable in Amazon
# Linux 2023's default repos). See docs/architecture.md for why this one
# instance carries three roles and how ignition/haproxy config updates
# reach it after this initial boot (haproxy-config module's SSM push, plus
# the self-heal timer this script installs).
set -euo pipefail

dnf install -y docker bind-utils awscli
systemctl enable --now docker

mkdir -p /etc/coredns /etc/haproxy /var/ignition-serve/ignition /var/ignition-serve/haproxy

# ---- CoreDNS: everything resolves to this instance's own (pinned) IP ----

cat > /etc/coredns/Corefile <<'COREFILE_EOF'
${base_domain}:53 {
    file /etc/coredns/zonefile
    errors
    log
}
.:53 {
    forward . ${upstream_dns}
    errors
    log
}
COREFILE_EOF

cat > /etc/coredns/zonefile <<'ZONEFILE_EOF'
$ORIGIN ${base_domain}.
$TTL 60
@                        IN SOA  ns.${cluster_name}.${base_domain}. admin.${cluster_name}.${base_domain}. ( 1 7200 3600 1209600 60 )
@                        IN NS   ns.${cluster_name}.${base_domain}.
ns.${cluster_name}       IN A    ${private_ip}
api.${cluster_name}      IN A    ${private_ip}
api-int.${cluster_name}  IN A    ${private_ip}
*.apps.${cluster_name}   IN A    ${private_ip}
ZONEFILE_EOF

docker run -d --name coredns --network host --restart always \
  -v /etc/coredns:/etc/coredns:ro \
  coredns/coredns:latest -conf /etc/coredns/Corefile

# ---- HAProxy: starts with empty backends; haproxy-config module fills them in later ----

cat > /etc/haproxy/haproxy.cfg <<'HAPROXY_EOF'
${haproxy_cfg}
HAPROXY_EOF

docker run -d --name haproxy --network host --restart always --user root \
  -v /etc/haproxy:/usr/local/etc/haproxy:ro \
  haproxytech/haproxy-alpine:latest \
  haproxy -W -f /usr/local/etc/haproxy/haproxy.cfg

# ---- Ignition HTTP server: serves whatever sync-config.sh has pulled from S3 ----

docker run -d --name ignition-http --network host --restart always \
  -v /var/ignition-serve:/www:ro \
  busybox:latest busybox httpd -f -p 8080 -h /www

# ---- self-heal: poll S3 for ignition/haproxy-config changes, reload on change ----
# Belt-and-suspenders alongside the haproxy-config module's SSM-driven push --
# covers the case where an SSM push itself is lost to a transient network
# issue, without requiring another `terraform apply`.

cat > /usr/local/bin/sync-config.sh <<'SYNC_EOF'
#!/bin/bash
set -euo pipefail

aws s3 sync s3://${ignition_bucket_name}/ignition/ /var/ignition-serve/ignition/ --region ${aws_region} --only-show-errors

NEW_ETAG=$(aws s3api head-object --bucket ${ignition_bucket_name} --key haproxy/haproxy.cfg --region ${aws_region} --query ETag --output text 2>/dev/null || echo "")
CUR_ETAG=""
[ -f /etc/haproxy/.last-etag ] && CUR_ETAG=$(cat /etc/haproxy/.last-etag)

if [ -n "$NEW_ETAG" ] && [ "$NEW_ETAG" != "$CUR_ETAG" ]; then
  aws s3 cp s3://${ignition_bucket_name}/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg --region ${aws_region}
  docker exec haproxy haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg
  docker kill --signal=HUP haproxy
  echo "$NEW_ETAG" > /etc/haproxy/.last-etag
fi
SYNC_EOF
chmod +x /usr/local/bin/sync-config.sh

cat > /etc/systemd/system/sync-config.service <<'SVC_EOF'
[Unit]
Description=Pull ignition/haproxy-config updates from S3 and reload HAProxy on change

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sync-config.sh
SVC_EOF

cat > /etc/systemd/system/sync-config.timer <<'TIMER_EOF'
[Unit]
Description=Run sync-config.service periodically

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s

[Install]
WantedBy=timers.target
TIMER_EOF

systemctl daemon-reload
systemctl enable --now sync-config.timer
