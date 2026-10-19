# Terraform walkthrough — VPC + EC2 + CloudFront + S3

A full explanation of this project: the architecture and data flow, how to find things in the docs, the HCL syntax, then every file explained in build order, block by block, line by line, plus how to run it.

```
Users → CloudFront ──default──▶ ALB (public subnets) → EC2 Auto Scaling Group (private subnets)
                   └─/static/*─▶ S3 bucket (private, via Origin Access Control)
EC2 → S3 (IAM role)         EC2 outbound → NAT Gateway → Internet Gateway
```

```
vpc-ec2-cloudfront-s3/
├── versions.tf          # Terraform + provider versions
├── providers.tf         # AWS provider + default tags
├── variables.tf         # root inputs
├── main.tf              # calls the five modules
├── outputs.tf           # CloudFront URL, ALB DNS, bucket name
├── terraform.tfvars     # dev values (auto-loaded)
├── prod.tfvars          # prod values (-var-file)
├── backend.tf.example   # optional remote state
└── modules/
    ├── network/         # VPC, public/private subnets, AZs, IGW, NAT, routes
    ├── security/        # ALB SG (from CloudFront prefix list) + web SG
    ├── storage/         # private S3 bucket (versioned, encrypted)
    ├── web/             # EC2 launch template, ALB, target group, listener, ASG, IAM
    └── cdn/             # CloudFront distribution, Origin Access Control, bucket policy
```

> **Order:** Section 0 = diagram + data flow, 0.1 = docs, 0.2 = syntax. Then every file once, in build order: foundations → network → security → storage → web → cdn → root → run.

---

# 0. The architecture and how data flows

- **CloudFront** is the only public entry point (an edge CDN). It has **two origins**:
  - the **ALB** (default behavior) — dynamic traffic.
  - the **S3 bucket** (path `/static/*`) — static files, read privately via **Origin Access Control (OAC)**.
- The **VPC** (`10.30.0.0/16`) spans **two Availability Zones**, each with a **public** subnet (ALB, NAT) and a **private** subnet (EC2).
- EC2 web servers run in **private** subnets inside an **Auto Scaling Group** behind the ALB.

## Request flow (steps)
1. A **user** hits the CloudFront URL.
2. If the path matches **`/static/*`**, CloudFront fetches the object straight from the **private S3 bucket** using OAC (S3 never goes public).
3. Otherwise (**default**) CloudFront forwards to the **ALB** in the public subnets. The ALB security group only accepts traffic from CloudFront's edge IP ranges (a managed prefix list).
4. The ALB forwards to an **EC2** instance in a **private** subnet. The web security group only accepts traffic from the ALB.
5. EC2 can read the **S3 bucket** through its **IAM role**, and reaches the internet (updates) **outbound only** via **NAT → IGW**.
6. Responses return up the same chain to the user.

## Security chain
`internet → CloudFront → ALB SG (CloudFront prefix list) → Web SG (ALB only)`, and S3 is reachable **only** by this CloudFront distribution (bucket policy + OAC).

## Provisioning flow
`terraform apply` → root module → five child modules → AWS provider → AWS APIs. Order from references: network → security → storage → web → cdn.

---

# 0.1 How to find anything in the Terraform docs

- Home of all docs: **`registry.terraform.io`**. Fast path: Google **`terraform <resource_name>`** → first result is the registry page.
- A resource doc page has 3 parts: **Example Usage**, **Argument Reference** (inputs you set), **Attribute Reference** (values you can read, like `.id`, `.arn`, `.dns_name`).
- Functions: **`developer.hashicorp.com/terraform/language/functions`**, or test live with `terraform console`.

| In the project | What to Google | Registry page |
|---|---|---|
| `aws_vpc` | `terraform aws_vpc` | resources/vpc |
| `aws_internet_gateway` | `terraform aws_internet_gateway` | resources/internet_gateway |
| `aws_subnet` | `terraform aws_subnet` | resources/subnet |
| `aws_eip` | `terraform aws_eip` | resources/eip |
| `aws_nat_gateway` | `terraform aws_nat_gateway` | resources/nat_gateway |
| `aws_route_table` | `terraform aws_route_table` | resources/route_table |
| `aws_route_table_association` | `terraform aws_route_table_association` | resources/route_table_association |
| `data.aws_ec2_managed_prefix_list` | `terraform aws_ec2_managed_prefix_list` | data-sources/ec2_managed_prefix_list |
| `aws_security_group` | `terraform aws_security_group` | resources/security_group |
| `aws_s3_bucket` (+ versioning/encryption/public_access_block) | `terraform aws_s3_bucket` | resources/s3_bucket |
| `aws_s3_bucket_policy` | `terraform aws_s3_bucket_policy` | resources/s3_bucket_policy |
| `data.aws_ami` | `terraform aws_ami data source` | data-sources/ami |
| `data.aws_iam_policy_document` | `terraform aws_iam_policy_document` | data-sources/iam_policy_document |
| `aws_iam_role` / `_role_policy` / `_role_policy_attachment` / `_instance_profile` | `terraform aws_iam_role` | resources/iam_role … |
| `aws_launch_template` | `terraform aws_launch_template` | resources/launch_template |
| `aws_lb` / `aws_lb_target_group` / `aws_lb_listener` | `terraform aws_lb` | resources/lb … |
| `aws_autoscaling_group` / `aws_autoscaling_policy` | `terraform aws_autoscaling_group` | resources/autoscaling_group |
| `aws_cloudfront_origin_access_control` | `terraform cloudfront origin access control` | resources/cloudfront_origin_access_control |
| `aws_cloudfront_distribution` | `terraform aws_cloudfront_distribution` | resources/cloudfront_distribution |
| `data.aws_availability_zones` | `terraform aws_availability_zones` | data-sources/availability_zones |

> `data.` prefix = a **data source** (read-only lookup), under **data-sources/** not **resources/**.

---

# 0.2 HCL syntax & functions — primer

- **Block**: a `{ }` chunk — `TYPE "LABEL1" "LABEL2" { ... }`. Inside are **arguments** (`name = value`).
- **Interpolation**: `"${var.project}-vpc"` runs the expression in `${ }` inside a string.
- **Reference**: `type.name.attribute` (e.g. `aws_vpc.this.id`); `var.x`, `module.m.out`, `data.x.y`.
- **Functions** (call as `name(args)`): `length(x)` counts, `slice(list,from,to)` takes part of a list, `cidrsubnet(prefix,newbits,netnum)` carves a subnet (`cidrsubnet("10.30.0.0/16",8,10)` → `10.30.10.0/24`), `base64encode(s)` for EC2 user-data.
- **Heredoc**: `<<-EOT ... EOT` is one multi-line string (the `-` allows indentation).
- **Conditional (the HCL "if")**: `condition ? value_if_true : value_if_false`.
- **`count` / `count.index`**: make N copies, numbered 0,1,2…; addressed `res[0]`. **Splat `[*]`**: `res[*].id` = every id as a list.
- **Wildcard vs regex**: the AMI `values = ["al2023-ami-*-x86_64"]` uses a **glob** `*` (filter feature), not regex. Real regex lives in `regex()` / `regexall()` / `can()`.
- **IAM JSON**: `data.aws_iam_policy_document` builds policy JSON from HCL; `.json` is the finished text.

---

# 1. `versions.tf`
📖 `terraform required_providers`
```hcl
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}
```
- `required_version` — minimum Terraform CLI. `required_providers.aws` — download `hashicorp/aws`. `~> 5.40` — allow 5.40 up to <6.0.

# 2. `providers.tf`
📖 `terraform aws provider`, `default_tags`
```hcl
provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
```
- `region` from a variable. `default_tags` — tags stamped on every taggable resource. No credentials here — the provider finds them from env vars, `~/.aws/credentials`, or an IAM role.

# 3. `variables.tf` (root)
📖 `terraform input variables`
```hcl
variable "region"           { type = string  default = "eu-west-1" }
variable "project"          { type = string  default = "webstack" }
variable "environment"      { type = string  default = "dev" }
variable "vpc_cidr"         { type = string  default = "10.30.0.0/16" }
variable "az_count"         { type = number  default = 2 }
variable "instance_type"    { type = string  default = "t3.micro" }
variable "min_size"         { type = number  default = 2 }
variable "max_size"         { type = number  default = 4 }
variable "desired_capacity" { type = number  default = 2 }
variable "cpu_target"       { type = number  default = 50 }
```
- Inputs with defaults (so all optional): region, project/name prefix, environment tag, network range, AZ count, EC2 size, ASG bounds, and the CPU scaling target. Reference as `var.region`, etc.

---

# 4. `modules/network`

## 4.1 variables.tf
```hcl
variable "project"  { type = string }
variable "vpc_cidr" { type = string }
variable "az_names" { type = list(string) }
```

## 4.2 main.tf

### VPC — 📖 `aws_vpc`
```hcl
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "${var.project}-vpc" }
}
```
- Create the VPC with the given range; enable DNS so the ALB and instances get names.

### Internet gateway — 📖 `aws_internet_gateway`
```hcl
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project}-igw" }
}
```
- The VPC's public door; `vpc_id` attaches it (and builds the VPC first).

### Public subnets — 📖 `aws_subnet`, `cidrsubnet`
```hcl
resource "aws_subnet" "public" {
  count                   = length(var.az_names)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = var.az_names[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name = "${var.project}-public-${count.index + 1}"
    Tier = "public"
  }
}
```
- `count` = one per AZ. `cidrsubnet(...,8,count.index)` → `10.30.0.0/24`, `10.30.1.0/24`. `availability_zone` spreads them. `map_public_ip_on_launch` = public.

### Private subnets
```hcl
resource "aws_subnet" "private" {
  count             = length(var.az_names)
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = var.az_names[count.index]
  tags = {
    Name = "${var.project}-private-${count.index + 1}"
    Tier = "private"
  }
}
```
- `count.index + 10` → `10.30.10.0/24`, `10.30.11.0/24`. No public IP mapping.

### EIP + NAT — 📖 `aws_eip`, `aws_nat_gateway`
```hcl
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project}-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.project}-nat" }
  depends_on    = [aws_internet_gateway.this]
}
```
- A static public IP for the NAT. The NAT lives in a **public** subnet, gives private instances **outbound-only** internet. `depends_on` the IGW.

### Route tables + routes — 📖 `aws_route_table`
```hcl
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.project}-rt-public" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }
  tags = { Name = "${var.project}-rt-private" }
}
```
- Public: `0.0.0.0/0 → IGW` (makes it public). Private: `0.0.0.0/0 → NAT` (outbound only).

### Associations — 📖 `aws_route_table_association`
```hcl
resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
```
- One association per subnet, tying each to its tier's route table.

## 4.3 outputs.tf
```hcl
output "vpc_id"             { value = aws_vpc.this.id }
output "public_subnet_ids"  { value = aws_subnet.public[*].id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
```
- The splat `[*]` returns every subnet id as a list.

---

# 5. `modules/security`

## 5.1 variables.tf
```hcl
variable "project" { type = string }
variable "vpc_id"  { type = string }
```

## 5.2 main.tf

### CloudFront prefix list lookup — 📖 `aws_ec2_managed_prefix_list`
```hcl
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}
```
- A data source that returns AWS's **managed list of CloudFront edge IP ranges**. We use it so only CloudFront can reach the ALB.

### ALB security group — 📖 `aws_security_group`
```hcl
resource "aws_security_group" "alb" {
  name        = "${var.project}-alb-sg"
  description = "Allow HTTP from CloudFront edge locations only"
  vpc_id      = var.vpc_id
  ingress {
    description     = "HTTP from CloudFront"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project}-alb-sg" }
}
```
- Inbound 80 **from the CloudFront prefix list** (not the whole internet) — `prefix_list_ids` instead of `cidr_blocks`. Egress all.

### Web security group
```hcl
resource "aws_security_group" "web" {
  name        = "${var.project}-web-sg"
  description = "Allow HTTP from the ALB only"
  vpc_id      = var.vpc_id
  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project}-web-sg" }
}
```
- Inbound 80 **from the ALB's SG only** — chained firewall.

## 5.3 outputs.tf
```hcl
output "alb_sg_id" { value = aws_security_group.alb.id }
output "web_sg_id" { value = aws_security_group.web.id }
```

---

# 6. `modules/storage`

## 6.1 variables.tf
```hcl
variable "project" { type = string }
```

## 6.2 main.tf — 📖 `aws_s3_bucket` (+ versioning/encryption/public_access_block)
```hcl
resource "aws_s3_bucket" "assets" {
  bucket_prefix = "${var.project}-assets-"
  force_destroy = true
  tags          = { Name = "${var.project}-assets" }
}

resource "aws_s3_bucket_versioning" "assets" {
  bucket = aws_s3_bucket.assets.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id
  rule { apply_server_side_encryption_by_default { sse_algorithm = "AES256" } }
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket                  = aws_s3_bucket.assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```
- `bucket_prefix` — unique name. `force_destroy` — allow destroy with objects (lab). Versioning keeps old versions. Encryption = AES256 at rest. The public-access block (all four `true`) keeps it **private** — CloudFront reads it via OAC, not publicly.

## 6.3 outputs.tf
```hcl
output "bucket_id"                   { value = aws_s3_bucket.assets.id }
output "bucket_name"                 { value = aws_s3_bucket.assets.bucket }
output "bucket_arn"                  { value = aws_s3_bucket.assets.arn }
output "bucket_regional_domain_name" { value = aws_s3_bucket.assets.bucket_regional_domain_name }
```
- `bucket_regional_domain_name` is what CloudFront uses as the S3 origin.

---

# 7. `modules/web` (EC2 + ALB + IAM)

## 7.1 variables.tf
```hcl
variable "project"            { type = string }
variable "vpc_id"             { type = string }
variable "instance_type"      { type = string }
variable "public_subnet_ids"  { type = list(string) }
variable "private_subnet_ids" { type = list(string) }
variable "alb_sg_id"          { type = string }
variable "web_sg_id"          { type = string }
variable "bucket_arn"         { type = string }
variable "bucket_name"        { type = string }
variable "min_size"           { type = number }
variable "max_size"           { type = number }
variable "desired_capacity"   { type = number }
variable "cpu_target"         { type = number }
```

## 7.2 main.tf

### AMI lookup — 📖 `aws_ami`
```hcl
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}
```
- Finds the newest Amazon Linux 2023 image (`*` is a glob).

### IAM role + policies + instance profile — 📖 `aws_iam_role`, `aws_iam_policy_document`, `aws_iam_role_policy_attachment`, `aws_iam_role_policy`, `aws_iam_instance_profile`
```hcl
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "web" {
  name               = "${var.project}-web-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.web.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "s3_read" {
  statement {
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [var.bucket_arn, "${var.bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "s3_read" {
  name   = "${var.project}-s3-read"
  role   = aws_iam_role.web.id
  policy = data.aws_iam_policy_document.s3_read.json
}

resource "aws_iam_instance_profile" "web" {
  name = "${var.project}-web-profile"
  role = aws_iam_role.web.name
}
```
- `assume` = the trust policy (EC2 may assume this role). The role attaches the managed **SSM** policy (shell in without SSH) plus a **least-privilege S3 read** inline policy for the assets bucket. The **instance profile** lets an EC2 instance use the role.

### Launch template — 📖 `aws_launch_template`, `base64encode`
```hcl
resource "aws_launch_template" "web" {
  name_prefix            = "${var.project}-"
  image_id               = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  vpc_security_group_ids = [var.web_sg_id]

  iam_instance_profile { name = aws_iam_instance_profile.web.name }

  user_data = base64encode(<<-EOT
    #!/bin/bash
    dnf install -y nginx
    cat > /usr/share/nginx/html/index.html <<HTML
    <h1>${var.project} dynamic tier on $(hostname)</h1>
    <p>static assets served by CloudFront from bucket: ${var.bucket_name}</p>
    HTML
    systemctl enable --now nginx
  EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags = { Name = "${var.project}-web" }
  }
}
```
- Blueprint for each EC2 instance: the AMI, size, web SG, instance profile, and a base64 user-data script that installs nginx and writes a page (hostname + bucket). The nested `<<HTML … HTML` is a heredoc inside the shell script.

### ALB + target group + listener — 📖 `aws_lb`, `aws_lb_target_group`, `aws_lb_listener`
```hcl
resource "aws_lb" "web" {
  name               = "${var.project}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids
  tags               = { Name = "${var.project}-alb" }
}

resource "aws_lb_target_group" "web" {
  name     = "${var.project}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id
  health_check {
    path                = "/"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
  tags = { Name = "${var.project}-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}
```
- Internet-facing ALB in the public subnets. Target group on 80 with a `/` → `200` health check. Listener on 80 forwards to the target group.

### Auto Scaling Group + policy — 📖 `aws_autoscaling_group`, `aws_autoscaling_policy`
```hcl
resource "aws_autoscaling_group" "web" {
  name                = "${var.project}-asg"
  vpc_zone_identifier = var.private_subnet_ids
  target_group_arns   = [aws_lb_target_group.web.arn]
  health_check_type   = "ELB"
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = var.desired_capacity
  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }
  tag {
    key                 = "Name"
    value               = "${var.project}-web"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "cpu" {
  name                   = "${var.project}-cpu-target-tracking"
  autoscaling_group_name = aws_autoscaling_group.web.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.cpu_target
  }
}
```
- Launches instances in the **private** subnets, auto-registers them with the ALB target group, uses the ELB health check, and target-tracks average CPU to scale.

## 7.3 outputs.tf
```hcl
output "alb_dns_name" { value = aws_lb.web.dns_name }
```

---

# 8. `modules/cdn` (CloudFront + OAC + bucket policy)

## 8.1 variables.tf
```hcl
variable "project"                     { type = string }
variable "alb_dns_name"                { type = string }
variable "bucket_regional_domain_name" { type = string }
variable "bucket_id"                   { type = string }
variable "bucket_arn"                  { type = string }
```

## 8.2 main.tf

### Origin Access Control — 📖 `aws_cloudfront_origin_access_control`
```hcl
resource "aws_cloudfront_origin_access_control" "s3" {
  name                              = "${var.project}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}
```
- OAC lets CloudFront sign requests to the **private** S3 bucket, so the bucket never needs to be public.

### CloudFront distribution — 📖 `aws_cloudfront_distribution`
```hcl
resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  comment             = "${var.project} cdn"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  origin {
    origin_id   = "alb"
    domain_name = var.alb_dns_name
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  origin {
    origin_id                = "s3"
    domain_name              = var.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }

  default_cache_behavior {
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    forwarded_values {
      query_string = true
      cookies { forward = "all" }
    }
    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  ordered_cache_behavior {
    path_pattern           = "/static/*"
    target_origin_id       = "s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Name = "${var.project}-cdn" }
}
```
- Two **origins**: `alb` (a custom/HTTP origin) and `s3` (uses the OAC, no custom config).
- `default_cache_behavior` → send everything to the ALB; don't cache (ttl 0) since it's dynamic; forward query strings and cookies.
- `ordered_cache_behavior` for `/static/*` → send to S3; cache for an hour (`default_ttl 3600`); forward nothing.
- `viewer_protocol_policy = "redirect-to-https"` — force HTTPS to viewers. `cloudfront_default_certificate` — use the free `*.cloudfront.net` cert. `price_class` — limit edge locations (cheaper).

### S3 bucket policy — 📖 `aws_s3_bucket_policy`, `aws_iam_policy_document`
```hcl
data "aws_iam_policy_document" "s3" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${var.bucket_arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "assets" {
  bucket = var.bucket_id
  policy = data.aws_iam_policy_document.s3.json
}
```
- Grants `s3:GetObject` to the **CloudFront service**, but only when the request comes from **this exact distribution** (`AWS:SourceArn` condition). That's what makes "only this CloudFront can read the bucket" true.

## 8.3 outputs.tf
```hcl
output "distribution_domain_name" { value = aws_cloudfront_distribution.this.domain_name }
output "distribution_arn"         { value = aws_cloudfront_distribution.this.arn }
```

---

# 9. `main.tf` (root) — wire the five modules
📖 `terraform module block`, `aws_availability_zones`
```hcl
data "aws_availability_zones" "available" {
  state = "available"
}

module "network" {
  source   = "./modules/network"
  project  = var.project
  vpc_cidr = var.vpc_cidr
  az_names = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

module "security" {
  source  = "./modules/security"
  project = var.project
  vpc_id  = module.network.vpc_id
}

module "storage" {
  source  = "./modules/storage"
  project = var.project
}

module "web" {
  source             = "./modules/web"
  project            = var.project
  vpc_id             = module.network.vpc_id
  instance_type      = var.instance_type
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids
  alb_sg_id          = module.security.alb_sg_id
  web_sg_id          = module.security.web_sg_id
  bucket_arn         = module.storage.bucket_arn
  bucket_name        = module.storage.bucket_name
  min_size           = var.min_size
  max_size           = var.max_size
  desired_capacity   = var.desired_capacity
  cpu_target         = var.cpu_target
}

module "cdn" {
  source                      = "./modules/cdn"
  project                     = var.project
  alb_dns_name                = module.web.alb_dns_name
  bucket_regional_domain_name = module.storage.bucket_regional_domain_name
  bucket_id                   = module.storage.bucket_id
  bucket_arn                  = module.storage.bucket_arn
}
```
- The AZ lookup feeds `network` (first two AZs via `slice`). Each module reads the previous ones' outputs: `security`/`web` need the VPC id and SGs; `web` needs the subnets + bucket; `cdn` needs the ALB DNS + the bucket's domain/id/arn. Terraform derives the order: network → security → storage → web → cdn.

# 10. `outputs.tf` (root)
```hcl
output "cloudfront_url" { value = "https://${module.cdn.distribution_domain_name}" }
output "alb_dns_name"   { value = module.web.alb_dns_name }
output "assets_bucket"  { value = module.storage.bucket_name }
```
- `cloudfront_url` is the public URL to open after apply.

# 11. Values & environments
- `terraform.tfvars` — auto-loaded dev values.
- `prod.tfvars` — bigger sizes / `environment = "prod"`; use `-var-file="prod.tfvars"`.
- `backend.tf.example` — optional S3 + DynamoDB remote state (rename to `backend.tf`, fill in, re-`init`). Or use a `cloud {}` block for Terraform Cloud (not alongside an S3 backend).

---

# 12. How to run
```bash
terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
```
- Open the `cloudfront_url` output in a browser (CloudFront takes a few minutes to deploy). Upload a file under a `static/` prefix in the bucket to exercise the S3 path.
- Prod values: add `-var-file="prod.tfvars"` to plan/apply.
- Tear down: `terraform destroy`. The **NAT gateway, ALB, EC2, and CloudFront** cost money — destroy when done.
