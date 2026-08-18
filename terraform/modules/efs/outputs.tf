output "file_system_id" {
  value = aws_efs_file_system.this.id
}

output "dns_name" {
  value       = aws_efs_file_system.this.dns_name
  description = "<fs-id>.efs.<region>.amazonaws.com. Resolvable from nodes because the bastion's CoreDNS forwards non-cluster queries to the VPC resolver."
}

output "mount_target_ips" {
  value       = [for mt in aws_efs_mount_target.this : mt.ip_address]
  description = "Usable directly if DNS resolution is ever in doubt -- an NFS mount works fine against the IP."
}

output "security_group_id" {
  value = aws_security_group.efs.id
}
