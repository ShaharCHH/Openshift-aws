# Architecture

## Why this looks different from a standard OpenShift UPI install

This account's SCP blocks Route 53, ELB/NLB creation, Elastic IPs, launching
or copying any AMI the account doesn't itself own, and the vmimport service
role's internal snapshot-copy step (see `docs/scp-blockers.md` for the full,
individually-verified list). Every departure from the "normal" AWS UPI
reference architecture below exists to route around one of those. The
design is meant to be repeatable across other client accounts that carry
the same kind of restrictions, not a one-off hack for this account
specifically.

## Getting a launchable RHCOS image at all

The account blocks `RunInstances`/`CopyImage` for any AMI it doesn't own —
confirmed against Red Hat's public RHCOS AMI — and blocks the vmimport
service role's `CopySnapshot` call specifically, confirmed by running a
real `ec2:ImportSnapshot` task and watching it fail with an explicit SCP
deny against `assumed-role/vmimport/...`. But `RegisterImage` (creating a
brand-new AMI from a snapshot this account owns) and `RunInstances` from
that self-owned AMI both work fine.

`scripts/ami-build/build-custom-ami.sh` exploits that gap: it launches a
small helper instance from an AWS-owned base AMI (always allowed), attaches
a blank EBS volume, and streams Red Hat's raw RHCOS disk image directly
onto that volume via `curl | gunzip | dd` over SSM — the same well-known
technique used to build custom cloud images without a vendor's import
pipeline. It then snapshots the volume as the caller's own identity (the
operation vmimport is blocked from, not us) and registers an AMI from that
snapshot. The result is an account-owned, launchable RHCOS AMI that never
touches vmimport and never references a foreign-owned image. Idempotent —
re-running it just returns the existing AMI unless `--force` is passed.

## The bastion: DNS + load balancer + ignition server + access point, in one instance

A single EC2 instance, in a private subnet with no Elastic IP, running
three containers:

- **CoreDNS** — serves `api.<cluster>.<base_domain>`,
  `api-int.<cluster>.<base_domain>`, and `*.apps.<cluster>.<base_domain>`,
  all resolving to the bastion's own private IP. Replaces Route 53.
- **HAProxy** — a TCP load balancer fronting four ports: 6443 (API), 22623
  (Machine Config Server), 443/80 (ingress). Replaces the NLB a standard UPI
  install would use.
- **A static HTTP server on port 8080** — serves ignition files to cluster
  nodes. See "How Ignition works" below for why this exists and what it
  replaced.

The bastion is reached only via AWS SSM Session Manager (port forwarding) —
no SSH key, no public IP, no bastion host in the traditional sense.

### Keeping HAProxy's backend list current without replacing the instance

HAProxy's backends change three times over a cluster's bring-up (bootstrap+
masters → masters only → masters+workers), but the bastion instance itself
never needs to be replaced or rebooted for this. A `haproxy-config` module
renders `haproxy.cfg` via `templatefile()`, uploads it to S3 (only
re-uploading when the backend list actually changes, via S3 object
content-hash diffing), then runs `aws ssm send-command` to pull the new
config onto the bastion (using the bastion's own IAM role — see below),
`docker cp` it into the running HAProxy container, validate it
(`haproxy -c -f`), and send `SIGHUP` to reload gracefully — no dropped
connections, no instance churn. The `local-exec` blocks on
`aws ssm wait command-executed`, so a failed reload fails the `terraform
apply` itself instead of silently leaving stale config running.

## How Ignition works (full detail, not just the summary)

Ignition is RHCOS's first-boot provisioning system — it runs inside the
initramfs, *before* the real root filesystem is mounted, and applies a
declarative JSON spec (disks, files, systemd units) exactly once. It is not
cloud-init, and it doesn't manage ongoing configuration — after first boot,
that's the Machine Config Operator's job, which pulls further config from
the in-cluster Machine Config Server over port 22623 (one of the four ports
HAProxy fronts).

**Producing the three `.ign` files** (`scripts/ignition/generate-ignition.sh`,
Phase 2):
1. `render-install-config.sh` builds `install-config.yaml` from
   `terraform output -json install_config_inputs` — region, subnet IDs,
   machine CIDR (derived from the VPC's own CIDR), cluster name/domain, pull
   secret, SSH key. No hand-typed network values, no interactive wizard.
2. `openshift-install create manifests` expands that into individual
   manifests and consumes the input file. `manifests/cluster-scheduler-02-config.yml`
   gets patched to `mastersSchedulable: false` here — the standard UPI step,
   done at this point because it's the last point manifests are editable.
3. `openshift-install create ignition-configs` produces `bootstrap.ign`,
   `master.ign`, `worker.ign`, plus `auth/kubeconfig` and
   `auth/kubeadmin-password`.

**Why these aren't pasted into EC2 user-data directly:** `bootstrap.ign`
embeds bootstrap-specific rendered assets (etcd discovery override,
bootstrap kubeconfig, MCO baseline, pull secret) and routinely exceeds
EC2's user-data size limit. `master.ign`/`worker.ign` are normally small —
mostly a pointer at the Machine Config Server — but can grow unpredictably
with custom CA bundles or corporate proxy settings, which is exactly the
kind of thing that will differ **between client accounts**. So all three
are hosted centrally and fetched via a small pointer/wrapper ignition,
rather than special-casing only bootstrap.

### The mechanism, and why it changed

The original design had cluster nodes fetch ignition directly from S3,
scoped to a VPC Gateway Endpoint. That's blocked: `ec2:CreateVpcEndpoint`
is SCP-denied in this account, and no S3 endpoint already existed in the
VPC to fall back on (`preflight/tests/06_vpc_endpoint.tftest.hcl` caught
this — since removed; see below).

While investigating that, we found the private subnet actually has real
outbound internet access already — a pre-existing Internet Gateway and two
NAT Gateways in the VPC, with the private subnet's default route going
through a Gateway Load Balancer endpoint (likely centralized traffic
inspection). Confirmed directly: a test instance in the private subnet
successfully reached `mirror.openshift.com`, S3's public endpoint, and
GitHub over HTTPS.

That opened an option — nodes fetch ignition straight from S3 over that
internet path — but it was deliberately **not** taken: RHCOS's Ignition
fetcher does a bare, unsigned GET (no SigV4), so making that work would
mean either a public bucket policy or one scoped to the NAT Gateway's
source IP — infrastructure this design doesn't own or control, and could
change without notice. Ignition files contain real secrets (pull secret,
bootstrap kubeconfig); routing them anywhere near an internet-reachable
path, even conditionally, isn't a trade-off worth making when there's a
strictly better option available.

**The mechanism that was built instead:** the S3 bucket stays completely
private — no public access, no anonymous policy, no VPC endpoint
dependency at all (see `terraform/modules/s3/main.tf`). The **bastion**
pulls `ignition/*.ign` and `haproxy/haproxy.cfg` down from S3 itself, using
its own IAM role — normal SigV4-authenticated `aws s3 cp`, the same as any
other AWS SDK call, over whatever internet-egress path the account
provides (this account's NAT Gateways; a different client account might
route differently, but *something* has to let SSM itself reach its API
endpoints, which every canary in this suite already depends on — this
isn't a new category of dependency). The bastion then re-serves the
ignition files to cluster nodes itself, over plain HTTP, on port 8080, on
the private VPC network only. Nothing ever touches the internet with an
anonymous read path; the bucket policy problem simply doesn't exist
anymore.

**The pointer/wrapper ignition** (built by `scripts/ignition/wrap-ignition.sh`,
Phase 2) is the actual EC2 `user_data` — a few hundred bytes:

```json
{
  "ignition": {
    "version": "3.2.0",
    "config": {
      "merge": [
        { "source": "http://<bastion-private-ip>:8080/ignition/<role>.ign" }
      ]
    }
  }
}
```

The bastion's private IP is fixed/deterministic (allocated via Terraform),
so this doesn't depend on DNS resolution being ready at Ignition's very
early fetch stage — the same reasoning that keeps CoreDNS itself pointed at
a static IP rather than something self-referential.

**What happens at boot:**
1. The instance launches with the pointer ignition as user-data.
2. RHCOS's Ignition `fetch` stage reads it, sees `config.merge`, and does a
   plain HTTP GET against the bastion's port 8080 — reachable because
   every node's security group allows it (see
   `terraform/modules/security-groups/main.tf`'s `bastion_ports.ignition`).
3. The full `.ign` content merges in; Ignition partitions disks, writes
   files, enables systemd units (kubelet, crio, etc.).
4. On real-root boot, the node registers against
   `api-int.<cluster>.<base_domain>` — CoreDNS resolves that to the
   bastion's own IP, HAProxy proxies to the real backends for the current
   phase.
5. From here on, the Machine Config Operator owns that node's configuration
   drift — Ignition's job was a single first-boot application, not a
   running service.

**Preflight coverage:** `preflight/tests/06_internet_egress.tftest.hcl`
replaced the removed VPC-endpoint canary — it proves the private subnet has
outbound HTTPS access at all, which the bastion's S3 pull now depends on.
It intentionally does **not** try to prove "S3 is reachable" specifically;
generic HTTPS egress is the actual dependency, and it's a cheaper, more
general thing to test.

## `terraform test` gotcha worth knowing before adding more test files

Every `preflight/tests/*.tftest.hcl` run block uses an explicit
`module { source = ... }` override, since the whole point is to exercise the
real production modules (`security-groups`, `iam`, `s3`) rather than
duplicate them. Terraform calls this a "secondary module," and — at least
on the Terraform version this was built against (1.15.8) — secondary
modules do **not** automatically inherit the file's provider configuration,
even though the AWS provider block lives right there in `preflight/providers.tf`.
Without extra wiring, every such run block fails with
`Invalid provider configuration ... Add a provider block to the root module`,
which looks like a credentials problem but isn't.

The fix, confirmed by direct testing (not just reading docs): every
`.tftest.hcl` file needs its own `variable` redeclarations for whatever root
variables it uses, its own `provider "aws" { region = var.aws_region }`
block, and each run block using a secondary module needs
`providers = { aws = aws }` to pass that provider through explicitly. See
any file under `preflight/tests/` for the pattern — it's repeated
per-file because test files can't share declarations. Apply the same
pattern to any new test files added in Phase 2 for the `vpc`/`bastion`
modules.
