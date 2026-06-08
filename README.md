# hantt-company-test

Multi-OS HTTPS web service on AWS, built with immutable AMIs via Packer + Ansible, deployed with Terraform, authenticated through Azure AD OIDC federation — no static AWS credentials.

---

## 1. Execution Summary

| Step | Outcome | Duration |
|------|---------|----------|
| Generate certificate | Self-signed cert written to `packer/shared/ssl/` | <1s |
| Packer — Linux AMI | `ami-0518e6dd6cb17839d` built successfully | 7m 52s |
| Packer — Windows AMI | `ami-03c1519b76d470c78` built successfully | 10m 48s |
| Terraform apply | 26 resources created | ~4m |
| HTTPS curl tests | 8 / 8 requests HTTP 200, round-robin across Linux + Windows | ~1m |
| Terraform destroy | 26 resources destroyed | ~8m |
| AMI cleanup | Both AMIs deregistered, both EBS snapshots deleted | ~14s |

All execution output is captured in [`logs/`](logs/).

---

## 2. Tools and Versions

| Tool | Version |
|------|---------|
| OpenSSL | system (certificate generation) |
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
- **IAM:** instance profile with `AmazonSSMManagedInstanceCore` + `AmazonS3ReadOnlyAccess`; IMDSv2 enforced
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

TASK [Install nginx]          changed
TASK [Create SSL directory]   changed
TASK [Upload SSL certificate] changed
TASK [Upload SSL private key] changed
TASK [Deploy Nginx HTTPS config] changed
TASK [Deploy welcome page]    changed
TASK [Enable and start Nginx] changed

PLAY RECAP: ok=9  changed=7  failed=0

Build 'hantt-nginx-linux.amazon-ebs.linux' finished after 7 minutes 52 seconds.
AMIs were created — ap-southeast-6: ami-0518e6dd6cb17839d
```

### 4.2 Packer — Windows AMI (`logs/2-packer-windows.log`)

Packer launches a Windows Server 2022 instance, waits for WinRM (via the `winrm-setup.ps1` user-data), then runs the Ansible playbook over WinRM. Nginx is installed via Chocolatey and registered as a Windows service via NSSM.

```
==> hantt-nginx-windows.amazon-ebs.windows: WinRM connected.
==> hantt-nginx-windows.amazon-ebs.windows: Provisioning with Ansible...

TASK [Install Chocolatey]                                          changed
TASK [Install Nginx and NSSM]                                      changed
TASK [Find nginx install directory]                                changed
TASK [Create SSL directory]                                        changed
TASK [Upload SSL certificate]                                      changed
TASK [Upload SSL private key]                                      changed
TASK [Deploy Nginx HTTPS config]                                   changed
TASK [Deploy welcome page]                                         changed
TASK [Register nginx as Windows service via NSSM]                  changed
TASK [Start nginx service]                                         changed
TASK [Open firewall for HTTPS]                                     changed

PLAY RECAP: ok=14  changed=12  failed=0

Build 'hantt-nginx-windows.amazon-ebs.windows' finished after 10 minutes 48 seconds.
AMIs were created — ap-southeast-6: ami-03c1519b76d470c78
```

### 4.3 Terraform Apply (`logs/3-terraform-apply.log`)

Deploys the VPC, subnets, NLB, security groups, IAM role, and both ASGs from the two AMIs produced above.

```
Apply complete! Resources: 26 added, 0 changed, 0 destroyed.

Outputs:
  nlb_dns_name = hantt-main-vpc-nlb-e4bc246b4bbb994b.elb.ap-southeast-6.amazonaws.com
  vpc_id       = vpc-040d8a184db39e4d1
```

### 4.4 HTTPS Curl Tests (`logs/4-curl-test.log`)

Script polls `describe-target-health` until both targets are healthy, then fires 8 requests. The NLB round-robins between the Linux and Windows instances.

```
  [0s]  healthy targets: 0 / 2
  [20s] healthy targets: 0 / 2
  [40s] healthy targets: 2 / 2  ✓ proceeding

--- Request 1 ---  Platform: Amazon Linux 2023 | Instance: i-03e553cca71d77f22 | [HTTP 200  0.114s]
--- Request 2 ---  Platform: Windows Server 2022 | Host: EC2AMAZ-29MLP2B       | [HTTP 200  0.096s]
--- Request 3 ---  Platform: Amazon Linux 2023 | Instance: i-03e553cca71d77f22 | [HTTP 200  0.022s]
--- Request 4 ---  Platform: Amazon Linux 2023 | Instance: i-03e553cca71d77f22 | [HTTP 200  0.025s]
--- Request 5 ---  Platform: Windows Server 2022 | Host: EC2AMAZ-29MLP2B       | [HTTP 200  0.032s]
--- Request 6 ---  Platform: Windows Server 2022 | Host: EC2AMAZ-29MLP2B       | [HTTP 200  0.035s]
--- Request 7 ---  Platform: Windows Server 2022 | Host: EC2AMAZ-29MLP2B       | [HTTP 200  0.032s]
--- Request 8 ---  Platform: Amazon Linux 2023 | Instance: i-03e553cca71d77f22 | [HTTP 200  0.020s]

8 / 8 requests succeeded over HTTPS (self-signed cert, -k flag used)
```

### 4.5 Terraform Destroy (`logs/5-terraform-destroy.log`)

```
Destroy complete! Resources: 26 destroyed.
```

### 4.6 AMI Cleanup (`logs/6-ami-cleanup.log`)

```
Deregistered: ami-0518e6dd6cb17839d  (Linux)
Deleted snapshot: snap-0af34046c36402a0f

Deregistered: ami-03c1519b76d470c78  (Windows)
Deleted snapshot: snap-04ea1458f37c7fdc4

All AMIs and snapshots removed from ap-southeast-6
```

---

## 5. Notes for Improvement

### 5.1 TLS Certificate Management

The current implementation bakes a self-signed certificate directly into the AMI. This works for a proof-of-concept but has a critical production problem: **certificates expire**. When the certificate expires, the AMI itself becomes invalid — every new instance launched from it will serve a broken HTTPS endpoint, and the fix requires a full AMI rebuild.

**Option A — AWS Certificate Manager (ACM) with a custom domain**

ACM issues and auto-renews certificates at no cost. The missing pieces for this implementation are:

1. A registered domain name (e.g. Route 53 or any registrar)
2. A Route 53 hosted zone with a DNS record pointing to the NLB
3. An ACM certificate attached to the NLB listener — the NLB terminates TLS; instances receive plain HTTP internally

This means the certificate lives entirely outside the AMI. The AMI never needs to be rebuilt for certificate rotation, and instances can serve plain HTTP on port 80 internally while the NLB handles encryption.

**Option B — Let's Encrypt with auto-renewal**

Let's Encrypt issues free 90-day certificates and provides tooling (`certbot`) to renew them automatically via HTTP-01 or DNS-01 challenges. On Linux this is straightforward. The tradeoff vs ACM is that renewal logic must run on the instance (or in a pipeline), and DNS-01 requires API access to the DNS provider — adding operational complexity that ACM eliminates entirely when already on AWS.

**Recommendation:** Use ACM + Route 53 for AWS-hosted workloads. The only additional resource needed is a domain name. ACM handles all renewal automatically, and TLS termination at the NLB removes the certificate concern from the AMI entirely.

---

### 5.2 Other Improvements

**Secrets and credentials**

- The self-signed certificate and private key are generated locally by `0-generate-certificate.sh` and excluded from source control via `.gitignore`. In production, certificates and keys should be stored in AWS Secrets Manager or SSM Parameter Store and fetched at instance boot rather than baked into an AMI.

**Networking**

- A NAT Gateway per AZ is needed for instances in private subnets to reach the internet. This has been intentionally omitted to keep the deployment simple; since all software is pre-baked into the AMI, runtime outbound access is not required for this exercise.
- The NLB uses TCP passthrough on port 443. This means the NLB cannot inspect HTTP headers, add `X-Forwarded-For`, or perform path-based routing. Switching to an Application Load Balancer (ALB) with ACM would enable all of these, plus HTTP→HTTPS redirect and host-based routing.

**Windows user-data dynamic page**

- The Windows launch template user-data (PowerShell) dynamically overwrites the baked-in `index.html` with live instance metadata (instance ID, AZ, IP). This works, but the Windows instance in these tests showed only hostname — the PowerShell IMDSv2 block ran against the static Packer-baked page because EC2Launch executes user-data after nginx is already running. A more reliable approach is to use an EC2Launch `executeScript` task in the AMI image itself, or use SSM Run Command to update the page post-boot.

**Observability**

- No access logging is enabled on the NLB. Enabling NLB access logs to S3 provides a request audit trail at minimal cost.
- No CloudWatch alarms are configured. At minimum, `HealthyHostCount` dropping below 1 should trigger an SNS alert.

**AMI lifecycle**

- There is no AMI retention policy. Each build produces a new AMI and snapshot that persist indefinitely (until manually cleaned up as in script 6). An automated retention policy (keep the last N AMIs, delete the rest) prevents unbounded snapshot costs.
