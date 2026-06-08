# hantt-company-test

Multi-OS HTTPS web service on AWS, built with immutable AMIs, deployed via Terraform, authenticated through Azure AD OIDC federation — no static AWS credentials.

## Architecture

```
Internet
    │ HTTPS :443
    ▼
[NLB] (multi-AZ: ap-southeast-6a + 6b)
    │  Security Group: 0.0.0.0/0:443 inbound only
    ▼
[Target Group :443 TCP]
    ├── ASG: Windows Server 2022 + Nginx (private subnets)
    └── ASG: Amazon Linux 2023 + Nginx  (private subnets)

VMs: ingress 443 restricted to NLB SG only (AWS 2023 NLB SG feature)
```

- Region: **ap-southeast-6** (Auckland, New Zealand)
- Two ASGs share one target group — NLB round-robins between Windows and Linux
- Each VM writes its own instance metadata (ID, AZ, IP, type) into the nginx HTML page at boot via IMDSv2 user_data

## Authentication

Azure Service Principal → OIDC token → AWS `assume-role-with-web-identity`

```bash
/home/ansible/secrets/azure-aws/get-token.sh
# writes token to /home/ansible/secrets/azure-aws/oidc-token
```

Required for both Terraform and Packer builds. No static AWS keys stored anywhere.

## Repository Structure

```
.
├── packer/
│   ├── shared/
│   │   └── ssl/
│   │       ├── server.crt      # self-signed cert (shared by both OS builds)
│   │       └── server.key
│   ├── linux/
│   │   ├── linux.pkr.hcl
│   │   └── ansible/
│   │       ├── playbook.yml
│   │       └── templates/
│   │           ├── https.conf.j2
│   │           └── index.html.j2
│   └── windows/
│       ├── windows.pkr.hcl
│       ├── winrm-setup.ps1     # enables WinRM SSL for Packer communication
│       └── ansible/
│           ├── playbook.yml
│           └── templates/
│               ├── nginx.conf.j2
│               └── index.html.j2
└── terraform/
    └── vpc/
        ├── main.tf             # provider (ap-southeast-6, regional STS, OIDC)
        ├── variables.tf
        ├── security_groups.tf  # NLB SG + VM SG (VM restricts to NLB SG)
        ├── nlb.tf              # NLB, target group, listener
        ├── asg.tf              # two launch templates + two ASGs + scaling policy
        ├── iam.tf              # instance profile for VMs
        └── outputs.tf
```

## SSL Certificate

The cert is generated once locally and shared between both AMI builds:

```bash
cd packer/shared/ssl
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout server.key -out server.crt \
  -subj "/CN=hantt-nginx/O=hantt/C=AU"
```

Both Linux (`copy`) and Windows (`win_copy`) Ansible playbooks upload from `packer/shared/ssl/`.

## Build AMIs

### Linux

```bash
export AWS_STS_REGIONAL_ENDPOINTS=regional
/home/ansible/secrets/azure-aws/get-token.sh
cd packer/linux
packer build linux.pkr.hcl
```

### Windows

```bash
export AWS_STS_REGIONAL_ENDPOINTS=regional
/home/ansible/secrets/azure-aws/get-token.sh
cd packer/windows
packer build windows.pkr.hcl
```

Windows build uses WinRM over SSL. Ansible uses `ansible.windows.win_powershell` (not `win_shell`) to avoid `CreateProcessW` permission errors when spawning child processes.

## Deploy Infrastructure

```bash
/home/ansible/secrets/azure-aws/get-token.sh

cd terraform/vpc
terraform init
terraform apply \
  -var="web_identity_token_file=/home/ansible/secrets/azure-aws/oidc-token" \
  -var="nginx_ami_id=<windows-ami-id>" \
  -var="linux_ami_id=<linux-ami-id>"
```

## Destroy Everything

```bash
/home/ansible/secrets/azure-aws/get-token.sh

# Destroy infrastructure
cd terraform/vpc
terraform destroy \
  -var="web_identity_token_file=/home/ansible/secrets/azure-aws/oidc-token" \
  -var="nginx_ami_id=<windows-ami-id>" \
  -var="linux_ami_id=<linux-ami-id>"

# Deregister AMIs and delete snapshots (get snapshot IDs first)
aws ec2 deregister-image --region ap-southeast-6 --image-id <ami-id>
aws ec2 delete-snapshot --region ap-southeast-6 --snapshot-id <snap-id>
```

## Key Design Decisions

| Decision | Reason |
|---|---|
| OIDC federation (no static keys) | Avoids long-lived credentials; Azure AD is the identity provider |
| Regional STS endpoint | ap-southeast-6 is an opt-in region; global STS rejects it |
| Cert generated locally | Avoids PATH/env issues with remote openssl after Chocolatey install |
| `win_powershell` not `win_shell` | `win_shell` spawns a child process blocked by Windows permissions |
| VM SG references NLB SG | AWS 2023 NLB SG feature — VMs never exposed to `0.0.0.0/0` |
| Two ASGs → one target group | Enables round-robin between Windows and Linux without extra listener rules |
