output "gateway_public_dns" {
  description = "Public DNS for the JSON API gateway."
  value       = aws_instance.gateway.public_dns
}

output "gateway_public_ip" {
  description = "Public IP for the JSON API gateway."
  value       = aws_instance.gateway.public_ip
}

output "engine_private_ip" {
  description = "Private IP for iii engine."
  value       = aws_instance.engine.private_ip
}

output "caller_private_ip" {
  description = "Private IP for caller worker."
  value       = aws_instance.caller.private_ip
}

output "inference_private_ip" {
  description = "Private IP for inference worker."
  value       = aws_instance.inference.private_ip
}
