output "vpc_id" {
  value = aws_vpc.this.id
}
output "private_subnet_ids" {
  value = [for s in aws_subnet.private : s.id]
}
output "public_subnet_ids" {
  value = [for s in aws_subnet.public : s.id]
}
output "app_sg_id" {
  value = aws_security_group.app.id
}
output "endpoint_sg_id" {
  value = aws_security_group.endpoints.id
}
