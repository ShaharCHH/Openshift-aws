output "instance_id" {
  value = aws_instance.bootstrap.id
}

output "private_ip" {
  value = aws_instance.bootstrap.private_ip
}
