# hantt-company-test

Demonstrates end-to-end platform engineering on AWS across the full stack:

- **Infrastructure as Code** — Terraform provisions a VPC with public/private subnets, NAT gateway, Network Load Balancer, Auto Scaling Groups, IAM roles, and security groups
- **Immutable AMIs** — Packer + Ansible builds separate AMIs for Amazon Linux 2023 and Windows Server 2022, each pre-configured with nginx serving HTTPS
- **Secrets management** — TLS certificate is stored in AWS Secrets Manager and fetched dynamically at instance boot, decoupling certificate lifecycle from AMI builds
- **Keyless authentication** — Azure AD service principal authenticates via OIDC federation (`AssumeRoleWithWebIdentity`) — no static AWS credentials anywhere in the pipeline
- **Multi-OS** — Linux and Windows instances run behind the same NLB target group, serving HTTPS with round-robin load balancing across both platforms

---

## 1. Execution Summary

| Step | Outcome | Duration |
|------|---------|----------|
| Generate certificate | Self-signed cert written to `packer/shared/ssl/`, uploaded to Secrets Manager | <1m |
| Packer — Linux AMI | `ami-06d4ac821dd7c2b7c` built successfully | 4m 50s |
| Packer — Windows AMI | `ami-092825995de360747` built successfully | 11m 56s |
| Terraform apply | 30 resources created | ~4m |
| HTTPS curl tests | 8 / 8 requests HTTP 200, round-robin across Linux + Windows | ~2m |
| Terraform destroy | 30 resources destroyed | ~8m |
| AMI cleanup | Both AMIs deregistered, both EBS snapshots deleted, Secrets Manager secret deleted | <1m |

Both Packer builds ran in parallel.

All execution output is captured in [`logs/`](logs/).

---

## 2. Tools and Versions

| Tool | Version |
|------|---------|
| OpenSSL | 3.0.17 |
| Azure CLI | 2.87.0 |
| Packer | 1.15.4 |
| Terraform | 1.15.5 |
| Ansible | core 2.14.18 |
| AWS CLI | 2.34.63 |
| hashicorp/aws provider | 5.100.0 |

---

## 3. Architecture

```
Internet
    │ HTTPS :443
    ▼
[Network Load Balancer]  (public subnets — ap-southeast-6a + 6b)
    │  Security Group: 0.0.0.0/0 → port 443 only
    ▼
[Target Group :443 TCP]
    ├── ASG: Amazon Linux 2023 + nginx  (private subnets)
    └── ASG: Windows Server 2022 + nginx (private subnets)
         Security Group: port 443 from NLB SG only
```

- **Region:** ap-southeast-6 (Auckland, New Zealand)
- **VPC:** `10.0.0.0/16` — 2 public + 2 private subnets across two AZs
- **EC2 instances:** sit in private subnets; no direct internet exposure
- **NLB:** in public subnets; single entry point, round-robins between both ASGs
- **IAM:** instance profile with `AmazonSSMManagedInstanceCore`, `AmazonS3ReadOnlyAccess`, `CloudWatchAgentServerPolicy`, and an inline policy granting `secretsmanager:GetSecretValue` scoped to `hantt/nginx-ssl-cert`; IMDSv2 enforced
- **EBS:** all volumes gp3, encrypted at rest
- **Auth:** Azure Service Principal → OIDC token → `AssumeRoleWithWebIdentity` — no static AWS keys

### Repository Structure

```
.
├── 0-generate-certificate.sh   # Generate self-signed cert into packer/shared/ssl/ (not committed)
├── 1-packer-build-linux.sh     # Packer build: Amazon Linux 2023 AMI
├── 2-packer-build-windows.sh   # Packer build: Windows Server 2022 AMI
├── 3-terraform-apply.sh        # Deploy infrastructure
├── 4-curl-test.sh              # HTTPS smoke test (polls NLB health, fires 8 requests)
├── 5-terraform-destroy.sh      # Tear down infrastructure
├── 6-ami-cleanup.sh            # Deregister AMIs + delete snapshots
├── logs/                       # Captured execution output (proof of run)
├── packer/
│   ├── shared/ssl/             # Self-signed cert shared by both AMI builds (gitignored — run script 0 first)
│   ├── linux/
│   │   ├── linux.pkr.hcl
│   │   └── ansible/            # playbook: dnf install nginx, deploy cert + HTTPS config
│   └── windows/
│       ├── windows.pkr.hcl
│       ├── winrm-setup.ps1     # User-data: enables WinRM HTTPS for Packer
│       └── ansible/            # playbook: Chocolatey → nginx + NSSM service, cert + HTTPS config
└── terraform/vpc/
    ├── main.tf                 # Provider (ap-southeast-6, regional STS, OIDC)
    ├── variables.tf
    ├── security_groups.tf      # NLB SG + VM SG (VM ingress locked to NLB SG)
    ├── nlb.tf                  # NLB, target group :443 TCP, listener
    ├── asg.tf                  # Two launch templates + two ASGs + CPU scaling policy
    ├── iam.tf                  # Instance profile
    └── outputs.tf
```

---

## 4. Execution Logs

All scripts write to `logs/` and are run in order.

### 4.1 Packer — Linux AMI (`logs/1-packer-linux.log`)

Packer launches a temporary Amazon Linux 2023 instance, runs the Ansible playbook over SSH, snapshots it into an AMI, then terminates the instance.

```
==> hantt-nginx-linux.amazon-ebs.linux: Connected to SSH!
==> hantt-nginx-linux.amazon-ebs.linux: Provisioning with Ansible...

TASK [Install nginx and SSM agent]
TASK [Enable SSM agent]
TASK [Deploy Nginx HTTPS config]
TASK [Remove default Nginx HTTP config]
TASK [Deploy welcome page]
TASK [Enable Nginx (cert fetched from Secrets Manager at first boot via user-data)]

PLAY RECAP: ok=7  changed=4  failed=0

Build 'hantt-nginx-linux.amazon-ebs.linux' finished after 4 minutes 50 seconds.
AMIs were created — ap-southeast-6: ami-06d4ac821dd7c2b7c
```

### 4.2 Packer — Windows AMI (`logs/2-packer-windows.log`)

Packer launches a Windows Server 2022 instance, waits for WinRM (via the `winrm-setup.ps1` user-data), then runs the Ansible playbook over WinRM. Nginx is installed via Chocolatey and registered as a Windows service via NSSM.

```
==> hantt-nginx-windows.amazon-ebs.windows: WinRM connected.
==> hantt-nginx-windows.amazon-ebs.windows: Provisioning with Ansible...

TASK [Install Chocolatey]
TASK [Install Nginx, NSSM and AWS CLI]
TASK [Find nginx install directory]
TASK [Set nginx dir fact]
TASK [Create SSL directory]
TASK [Deploy Nginx HTTPS config]
TASK [Deploy welcome page]
TASK [Stop nginx if already running]
TASK [Register nginx as Windows service via NSSM if not already registered]
TASK [Start nginx service]
TASK [Open firewall for HTTPS]
TASK [Stamp nginx install path into AMI for user-data to consume]
TASK [Ensure SSM agent is installed and set to auto-start]
TASK [Reset EC2Launch v2 so user-data runs on first boot from this AMI]

PLAY RECAP: ok=15  changed=12  failed=0

Build 'hantt-nginx-windows.amazon-ebs.windows' finished after 11 minutes 56 seconds.
AMIs were created — ap-southeast-6: ami-092825995de360747
```

### 4.3 Terraform Apply (`logs/3-terraform-apply.log`)

Deploys the VPC, subnets, NLB, security groups, IAM role, and both ASGs from the two AMIs produced above.

```
Apply complete! Resources: 30 added, 0 changed, 0 destroyed.

Outputs:
  nlb_dns_name = hantt-main-vpc-nlb-a2b678a5dc3c34f9.elb.ap-southeast-6.amazonaws.com
  vpc_id       = vpc-0d7894ac074281692
```

### 4.4 HTTPS Curl Tests (`logs/4-curl-test.log`)

Script polls `describe-target-health` until both targets are healthy, then fires 8 requests. The NLB round-robins between the Linux and Windows instances.

```
  [0s]  healthy targets: 0 / 2
  [20s] healthy targets: 0 / 2
  [40s] healthy targets: 1 / 2
  [60s] healthy targets: 2 / 2  ✓ proceeding

--- Request 1 ---  Platform: Amazon Linux 2023    | Instance: i-002c41e85a1c05c71 | [HTTP 200  0.127s]
--- Request 2 ---  Platform: Windows Server 2022  | Instance: i-021896eda6184f089 | [HTTP 200  0.158s]
--- Request 3 ---  Platform: Amazon Linux 2023    | Instance: i-002c41e85a1c05c71 | [HTTP 200  0.023s]
--- Request 4 ---  Platform: Windows Server 2022  | Instance: i-021896eda6184f089 | [HTTP 200  0.033s]
--- Request 5 ---  Platform: Windows Server 2022  | Instance: i-021896eda6184f089 | [HTTP 200  0.032s]
--- Request 6 ---  Platform: Amazon Linux 2023    | Instance: i-002c41e85a1c05c71 | [HTTP 200  0.022s]
--- Request 7 ---  Platform: Amazon Linux 2023    | Instance: i-002c41e85a1c05c71 | [HTTP 200  0.021s]
--- Request 8 ---  Platform: Windows Server 2022  | Instance: i-021896eda6184f089 | [HTTP 200  0.031s]

8 / 8 requests succeeded over HTTPS (self-signed cert, -k flag used)
```

### 4.5 Terraform Destroy (`logs/5-terraform-destroy.log`)

```
Destroy complete! Resources: 30 destroyed.
```

### 4.6 AMI Cleanup (`logs/6-ami-cleanup.log`)

```
Deregistered: ami-06d4ac821dd7c2b7c  (Linux)
Deleted snapshot: snap-0f3aa5858ae8dc2e4

Deregistered: ami-092825995de360747  (Windows)
Deleted snapshot: snap-0e21ea211c78b2478

Deleted secret: hantt/nginx-ssl-cert

All AMIs, snapshots, and secrets removed from ap-southeast-6
```

---

## 5. Notes for Improvement

### 5.1 TLS Certificate Management

The certificate is stored in **AWS Secrets Manager** (`hantt/nginx-ssl-cert`) and fetched dynamically at instance boot via user-data — it is never baked into the AMI. Both the Linux and Windows launch templates retrieve the cert and key from Secrets Manager on first launch and write them to the nginx `ssl/` directory before starting the service. The IAM instance profile grants `secretsmanager:GetSecretValue` scoped to that secret.

This design demonstrates **separation of duty and flexibility**: certificate lifecycle (generation, renewal, rotation) is managed independently of VM launches and AMI builds. Rotating a certificate requires only updating the secret and cycling instances (e.g. via an ASG instance refresh) — no AMI rebuild needed. New instances always fetch the latest cert from Secrets Manager at boot automatically.

In production, this foundation makes it straightforward to go a step further:

- **ACM + NLB TLS listener** — ACM issues and auto-renews a certificate; the NLB terminates TLS at Layer 4 and forwards plain TCP to instances. Requires a custom domain for DNS validation but no changes to the instances.
- **ACM + ALB** — ALB terminates TLS at Layer 7 and adds `X-Forwarded-For` natively. Requires a custom domain for ACM certificate validation.
- **Let's Encrypt** — free 90-day certs with `certbot` auto-renewal. Works well on Linux; adds operational complexity since renewal logic must run on the instance or in a pipeline.

---

### 5.2 Other Improvements

**Secrets and credentials**

- The self-signed certificate and private key are generated locally by `0-generate-certificate.sh` and uploaded to AWS Secrets Manager. Instances fetch the cert from Secrets Manager at boot — the private key is never baked into an AMI.

**Networking**

- NLB operates at Layer 4 (TCP) and cannot read or write HTTP headers — `X-Forwarded-For` is not configurable on an NLB. Two paths forward: (1) enable **Proxy Protocol v2** on the target group and configure nginx to parse it, which surfaces the real client IP without changing the load balancer type; (2) switch to an **ALB**, which adds `X-Forwarded-For` natively and also enables path-based routing and HTTP→HTTPS redirect — but ALB requires TLS termination at the load balancer, meaning ACM and a real domain name (the same prerequisite as the certificate improvement above).


**Observability**

- No access logging is enabled on the NLB. Enabling NLB access logs to S3 provides a request audit trail at minimal cost.
- VM instance logging is not configured. The IAM instance profile already has `CloudWatchAgentServerPolicy` attached, so the permission is in place — the next step is installing and configuring the CloudWatch agent on both Linux and Windows AMIs to ship nginx access/error logs and OS-level logs to CloudWatch Logs.
- No CloudWatch alarms are configured. At minimum, `HealthyHostCount` dropping below 1 should trigger an SNS alert.

**AMI lifecycle**

- There is no AMI retention policy. Each build produces a new AMI and snapshot that persist indefinitely (until manually cleaned up as in script 6). An automated retention policy (keep the last N AMIs, delete the rest) prevents unbounded snapshot costs.
