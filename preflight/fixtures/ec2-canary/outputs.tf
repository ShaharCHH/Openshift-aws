output "instance_id" {
  value = aws_instance.canary.id
}

output "instance_state" {
  value = aws_instance.canary.instance_state
}
