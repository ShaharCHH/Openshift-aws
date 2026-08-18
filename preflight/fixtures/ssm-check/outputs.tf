output "status" {
  value = data.external.ssm_probe.result.status
}

output "detail" {
  value = try(data.external.ssm_probe.result.detail, "")
}
