# SCP Blockers

This account's Service Control Policy (SCP) blocks several AWS API calls the
"normal" OpenShift-on-AWS install path relies on. Each one has a workaround
baked into this repo's design. See `preflight/tests/` and
`scripts/preflight/scp-probes.sh` for how each row is actually verified
against a real account rather than assumed.

| # | Blocked operation | Workaround | Verified by |
|---|---|---|---|
| 1 | Route 53 (hosted zone management) | CoreDNS runs on the bastion instance; all cluster DNS records point at the bastion's own private IP | Design carried forward from the prior agent-based-install attempt; not independently re-probed (Route 53 creation isn't part of this UPI design at all, so there's nothing to test against) |
| 2 | `ec2:CreateVpc` | Use an existing client-provided VPC (`create_vpc = false` + `existing_vpc_id`) | `scripts/preflight/scp-probes.sh` |
| 3 | `ec2:AllocateAddress` (EIP) | No public IPs anywhere; bastion lives in a private subnet, reached only via SSM Session Manager | `scripts/preflight/scp-probes.sh` |
| 4 | `elasticloadbalancing:CreateLoadBalancer` | HAProxy runs on the bastion instance as a TCP load balancer (API/MCS/ingress) instead of an NLB | `scripts/preflight/scp-probes.sh` |
| 5 | `ec2:RunInstances` / `ec2:CopyImage` on any AMI this account doesn't own | Build our own AMI instead of using Red Hat's public one — `scripts/ami-build/build-custom-ami.sh` streams RHCOS's raw disk image onto a self-owned EBS volume via a helper instance (launched from an AWS-owned AMI, which *is* allowed), then snapshots + registers it as this account's own AMI | Real `UnauthorizedOperation` denials confirmed against `RunInstances` and `CopyImage` for the public RHCOS AMI; the self-registered-AMI path confirmed working end-to-end (disposable test AMI: register → launch → terminate, all succeeded) |
| 6 | `ec2:ImportSnapshot`/`ec2:ImportImage` (vmimport) | Don't use vmimport at all — see #5. Reviving the original agent-based-install approach is not viable in this account | Ran a real `ec2:ImportSnapshot` task (tiny throwaway file) against the real vmimport pipeline. It failed with an explicit SCP deny naming `assumed-role/vmimport/vm_import_image-...` — the **same policy ID** as #5, scoped specifically to the `vmimport` service-linked role's internal `CopySnapshot` call. Note: `ec2:CopySnapshot` called directly by a human/Terraform identity is *not* blocked — only vmimport's own use of it is, which is what makes #5's approach viable |
| 7 | `ec2:CreateVpcEndpoint` | Not needed anymore — see below | `preflight/tests/06_internet_egress.tftest.hcl` (indirectly; the VPC-endpoint-specific canary was removed once the design stopped depending on it) |

## Resolved: the VPC-endpoint dependency was designed away, not worked around

An earlier version of this design hosted ignition files in S3 and had
cluster nodes fetch them directly, scoped to an S3 Gateway VPC Endpoint.
`ec2:CreateVpcEndpoint` turned out to be SCP-blocked too, with no existing
endpoint in the VPC to fall back on. Rather than find a workaround for
*that* block, the design changed: the bastion now pulls ignition files from
a fully private S3 bucket using its own IAM role (normal authenticated
access, no VPC endpoint involved at all), and re-serves them to cluster
nodes over plain HTTP within the VPC. See `docs/architecture.md`'s "How
Ignition works" section for the full reasoning, including why "just let
nodes reach S3 over the internet" (which does work here — see below) was
considered and deliberately not chosen.

## Bonus finding: this account already has real internet egress

While investigating the VPC-endpoint problem, we found the VPC already has
an Internet Gateway and two NAT Gateways (pre-existing platform
infrastructure, not something this project provisions), with the private
subnet's default route passing through a Gateway Load Balancer endpoint
(likely centralized traffic inspection). Confirmed directly: a test
instance in the private subnet reached `mirror.openshift.com`, S3's public
endpoint, and GitHub over HTTPS without issue. This is what makes the
bastion's IAM-authenticated S3 pull (above) possible, and is exactly what
`06_internet_egress.tftest.hcl` checks for on a new account — a different
client account might not have this, and the bastion's ignition-serving
would fail closed without it.

## Reading the probe results

`scripts/preflight/scp-probes.sh` classifies each blocked-operation probe
three ways, not two:

- **PASS** — the call failed with an authorization error. The block is
  confirmed and the workaround above is still justified.
- **UNEXPECTED_SUCCESS** — the call succeeded. Flagged loudly (non-zero exit,
  immediate cleanup of whatever got created) because it means this
  particular client account may not need the workaround at all, or this
  account's SCP posture has changed since these rows were written.
- **INCONCLUSIVE** — the call failed for some OTHER reason (a parameter
  validation error, a missing prerequisite, etc.). Never treated as proof of
  an SCP block — reported distinctly so a human has to look.

Rows 5 and 6 above were **not** discovered via `scp-probes.sh` — they came
from real end-to-end attempts (a real `ImportSnapshot` task; real
`RunInstances`/`CopyImage`/`RegisterImage` calls) run manually while
investigating why the original agent-based-install attempt failed. The
automated probe script only covers rows 2–4; it doesn't yet have canaries
for the AMI-ownership or vmimport-specific findings, since those needed a
real (if disposable) AMI/import task to demonstrate, not a quick
allow/deny check.
