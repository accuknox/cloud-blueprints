provider "aws" {
}

resource "aws_iam_user" "accuknox" {
  name = "security-scanner"
}

resource "aws_iam_user_policy_attachment" "attach_readonly_policy" {
  user = aws_iam_user.accuknox.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_user_policy_attachment" "attach_security_audit_policy" {
  user = aws_iam_user.accuknox.name
  policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"
}

resource "aws_iam_access_key" "accuknox_access_key" {
  user = aws_iam_user.accuknox.name
}

resource "local_file" "credentials_file" {
  filename = "credentials.txt"
  content = <<EOT
  [default]
  aws_access_key_id = ${aws_iam_access_key.accuknox_access_key.id}
  aws_secret_access_key = ${aws_iam_access_key.accuknox_access_key.secret}
  EOT
}