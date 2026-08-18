output "instance_ids" {
  value = aws_instance.master[*].id
}

output "private_ips" {
  value = aws_instance.master[*].private_ip
}
