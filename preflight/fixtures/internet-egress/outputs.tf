output "status" {
  value = data.external.egress_probe.result.status
}

output "detail" {
  value = try(data.external.egress_probe.result.detail, "")
}
