resource "aws_kms_key" "this" {
  description             = "${var.name} CMK"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}
resource "aws_kms_alias" "this" {
  name          = "alias/${var.name}"
  target_key_id = aws_kms_key.this.key_id
}
