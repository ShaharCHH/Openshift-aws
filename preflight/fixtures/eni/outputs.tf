output "eni_id" {
  value = aws_network_interface.canary.id
}

output "private_ip" {
  value = aws_network_interface.canary.private_ip
}
