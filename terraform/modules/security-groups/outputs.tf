output "bastion_sg_id" {
  value = aws_security_group.bastion.id
}

output "master_sg_id" {
  value = aws_security_group.master.id
}

output "worker_sg_id" {
  value = aws_security_group.worker.id
}

output "bootstrap_sg_id" {
  value = aws_security_group.bootstrap.id
}
