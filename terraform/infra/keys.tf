resource "tls_private_key" "rsa_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}
resource "harvester_ssh_key" "harbor-key" {
  name      = "harbor-key"
  namespace = "default"

  public_key = tls_private_key.rsa_key.public_key_openssh
}
resource "local_sensitive_file" "harbor_key_pem" {
  filename        = "${path.module}/harbor"
  content         = tls_private_key.rsa_key.private_key_pem
  file_permission = "0600"
}