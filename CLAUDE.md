# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Terraform + shell tooling that installs **OpenShift 4.22 UPI on AWS in an account
whose SCP blocks most of the normal install path**. It is meant to be repeatable
across client accounts carrying similar restrictions, not a one-off.

Nearly every unusual design choice here routes around a specific, individually
verified API denial. Before changing something that looks over-complicated, read
`docs/scp-blockers.md` — the workaround probably exists because the obvious
approach was tried and returned an explicit deny.

### Documentation ownership

- `docs/architecture.md` — *why* the design looks like this. The durable record.
- `docs/runbook.md` — *what to run, in what order*, plus a troubleshooting table
  of failure signatures seen for real.
- `docs/scp-blockers.md` — the blocked operations, each with how it was verified.
- `docs/preflight.md` — running and reading the account-validation suite.
- `SESSION_STATE.md` — transient handoff, deleted once acted on. **If it
  disagrees with the docs above, they win.**

Findings belong in the durable docs, not only in a handoff file. A previous
session nearly lost the entire storage rationale by putting it only in
`SESSION_STATE.md`.

## Commands

Everything is keyed by an **account alias** matching `accounts/<alias>.tfvars`
(gitignored; `accounts/example.tfvars.sample` is the template). Examples use
`horizon`.

```bash
# Credentials for every command below
aws sso login --profile <profile> && export AWS_PROFILE=<profile>

# Phase 0 — validate a new account (skip on a validated one)
cd preflight && terraform init
../scripts/preflight/run-all.sh -a horizon      # exit 0 = every capability works
                                                # and every avoided op still blocked

# Phases 1-4 — bring-up. The ordering is load-bearing; see below.
cd terraform && terraform init
terraform apply -var-file=../accounts/horizon.tfvars                 # 1: bastion/IAM/S3/SGs
export TF_VAR_rhcos_ami_id=$(../scripts/ami-build/build-custom-ami.sh -a horizon)   # 2: ~10-15 min
../scripts/ignition/render-install-config.sh -a horizon \
  --pull-secret ~/pull-secret.json --ssh-key ~/.ssh/id_rsa.pub       # 3
../scripts/ignition/generate-ignition.sh -a horizon
export TF_VAR_mcs_ca_data_url=$(../scripts/ignition/extract-mcs-ca.sh -a horizon)
export TF_VAR_cluster_infra_id=$(../scripts/ignition/extract-infra-id.sh -a horizon)
terraform apply -var-file=../accounts/horizon.tfvars \
  -var="masters_enabled=true" -var="bootstrap_enabled=true"           # 4

# Finishing the build (day2/ — run once, in order, after install-complete)
./day2/apply-storage.sh -a horizon                 # EFS export root + efs-nfs StorageClass
./day2/verify-storage.sh -a horizon
./day2/setup-registry.sh -a horizon                # registry PVC + the S3-stanza patch
./day2/verify-registry.sh -a horizon               # build -> push -> pull round-trip
./day2/post-install-cleanup.sh -a horizon          # storage operator + dead StorageClasses

# Day-2 (scripts/ — run whenever)
./scripts/tunnel.sh -a horizon                     # SSM port-forward, 6443
sudo -E ./scripts/tunnel.sh -a horizon --all \
  --profile <profile>                              # 6443 + 443 (console)
./scripts/update-kubeconfig.sh -a horizon          # merge into ~/.kube/config
./scripts/cluster-health.sh -a horizon             # oc get co, known-inert three called out
./scripts/hibernate.sh -a horizon                  # stop instances (EBS still bills)
./scripts/wake.sh -a horizon
./scripts/teardown.sh -a horizon [--keep-bastion]  # asks for confirmation first
```

### Tests

`preflight/tests/*.tftest.hcl` is the only automated test suite — real
`terraform test` runs that create and destroy live AWS resources against the
target account. There is no offline test layer and no shell test framework.

```bash
cd preflight
terraform test                                     # whole suite (needs -var values;
                                                   # run-all.sh supplies them)
terraform test -filter=tests/04_ec2_launch.tftest.hcl   # a single test file
```

`run-all.sh` wraps the suite with the SCP-denial probes and a cleanup sweep, and
is the normal entry point. Shell changes: `shellcheck -x scripts/<name>.sh`
(only SC1091 on the `read-tfvars.sh` source is expected).

`07_efs.tftest.hcl` covers EFS — the entire storage design has no fallback if
it's blocked (no CSI driver can ever work here either), so `scp-probes.sh`
also probes `elasticfilesystem:CreateFileSystem` as an expected-ALLOW (a
`BLOCKED` result means the account has no storage answer at all) alongside the
expected-DENY `iam:CreateUser` / `iam:CreateOpenIDConnectProvider` probes.

## Architecture

### The credential wall — the single most important thing to understand

**Nothing running inside this cluster can hold an AWS credential.**
`credentialsMode: Manual`, and both ways of supplying one by hand are
SCP-denied (`iam:CreateUser`, `iam:CreateOpenIDConnectProvider`). The instance
profile is not a way out either: pods run on the OVN pod network, which does not
forward to `169.254.169.254`, so they cannot reach IMDS to borrow the node's
identity — raising the hop limit to 2 looks like the fix and measurably is not.

This one fact explains, and should not be re-debugged in, four separate places:

- no CSI driver can work → storage is **EFS spoken as plain NFS** (via
  `nfs-subdir-external-provisioner`, which only makes NFS calls)
- the image registry cannot use its S3 backend → it is PVC-backed on `efs-nfs`.
  S3 *is* reachable from the VPC; the obstacle is identity, not connectivity
- `control-plane-machine-set` Degraded, `storage` Degraded, `network` permanently
  `Progressing` — all inert, all the same missing credential. `docs/runbook.md`
  has the "Known-inert, do not chase" list

When a new operator misbehaves, the first question is "what identity does it
think it has?"

### The bastion is DNS + load balancer + ignition server + access point

One EC2 instance in a private subnet, no EIP, reachable only via SSM. It runs
CoreDNS (replacing Route 53), HAProxy (replacing the SCP-blocked ELB, fronting
6443/22623/443/80), and a static HTTP server on 8080 serving ignition.

Its private IP is **pinned** via `cidrhost(..., 250)` in `terraform/locals.tf`,
because it is baked into the RHCOS AMI as a kernel argument and embedded in the
pointer ignition. Offset 250, not 10 — the subnet is shared with other teams and
a low offset collided for real.

`modules/haproxy-config` updates the backend list **in place** across the
cluster lifecycle (bootstrap+masters → masters only) by uploading to S3 and
pushing over SSM with a validate-then-`SIGHUP` reload. The bastion instance is
never replaced or rebooted for a backend change, and a failed reload fails the
`terraform apply`.

### Ignition reaches nodes through the bastion, never S3 directly

`ec2:CreateVpcEndpoint` is denied, and RHCOS's Ignition fetcher does a bare
unsigned GET (no SigV4), so it cannot authenticate to S3. The bucket therefore
stays fully private; the **bastion** pulls with its own IAM role and re-serves
over plain HTTP on the VPC. Nodes boot from a few-hundred-byte pointer ignition
built inline with `jsonencode()` in `modules/control-plane` and `modules/bootstrap`.

The ignition HTTP server starts only *after* files are on disk — Ignition
retries a refused connection but treats HTTP 404 as fatal, so a server listening
on an empty directory kills every node booting in that window.

### Node networking is configured twice, on purpose

Not redundancy. Two moments that share nothing:

1. **Initramfs**, before any root filesystem, so Ignition can resolve `api-int`
   for its `config.merge` fetch → kernel args `ip=dhcp nameserver=<bastion-ip>`,
   patched into the AMI by `build-custom-ami.sh`. `nameserver=` without
   `ip=dhcp` hangs dracut with no console output.
2. **The real root**, for every later boot → a NetworkManager keyfile delivered
   through the wrapper ignition (mode 0600; NM ignores world-readable keyfiles).
   Without it, all masters reboot together on the MCO's first rendered config
   and come back with no address. A MachineConfig cannot do this job for
   bootstrap, which *is* the Machine Config Server.

`scripts/ami-build/verify-ami-reboot.sh` is the acceptance gate — first-boot
success proves nothing.

### Phase ordering and the transient `-var` values

`bastion apply → AMI build → ignition generation → full apply`. The AMI must be
built *after* the bastion exists, since the bastion IP becomes a kernel argument.

`rhcos_ami_id`, `mcs_ca_data_url` and `cluster_infra_id` live in the environment
as `TF_VAR_*` rather than tfvars, so tfvars history reflects steady-state config
rather than bring-up state. **Every subsequent apply must carry all three** —
dropping `cluster_infra_id` silently removes the cluster tag and re-breaks the
cloud-controller-manager. `masters_enabled` / `bootstrap_enabled` are likewise
CLI-only.

**Regenerate ignition in full on every rebuild.** `create manifests` mints a
fresh cluster CA and infraID each run; reusing yesterday's produces an x509
"unknown authority" loop that looks nothing like a stale-value problem.

### Install-time-only decisions

`scripts/ignition/generate-ignition.sh` writes an IngressController manifest
pinning `endpointPublishingStrategy: HostNetwork` between `create manifests` and
`create ignition-configs`. That field is immutable once the object exists, and
the AWS default (`LoadBalancerService`) tries to build an SCP-denied ELB —
leaving ingress `Available=False` forever and objects wedged on finalizers.

## Conventions

- **Scripts** take `-a <account-alias>`, source `scripts/lib/read-tfvars.sh`, and
  read config straight from `accounts/<alias>.tfvars` — no terraform state, no
  required working directory. Instance-discovery scripts find them by the
  `Project=openshift-upi` + `AccountAlias=<alias>` default tags; `oc`-based
  scripts read `.ignition/<alias>/auth/kubeconfig` directly rather than
  depending on `~/.kube/config` having been merged.
- **`day2/` vs `scripts/`**: `day2/` holds the run-once scripts that finish a
  build off after `openshift-install wait-for install-complete` — storage,
  registry, post-install cleanup (see `day2/README.md`). `scripts/` is
  everything meant to run repeatedly across a cluster's whole lifetime —
  access (`tunnel.sh`), lifecycle (`hibernate.sh`/`wake.sh`/`teardown.sh`),
  and diagnostics (`cluster-health.sh`, `check-known-inert.sh`). Both follow
  the same script conventions on this list; the split is about *when* you run
  something, not how it's written.
- **Target bash 3.2** — what macOS ships and what `/usr/bin/env bash` resolves to
  here. No `wait -n`, no associative arrays.
- `set -uo pipefail`, not `-e`, wherever a non-zero exit is normal input
  (supervise loops, deny-probes).
- Comments carry the *evidence*, not just intent. Existing ones record real probe
  output and failure signatures; match that when adding to them.
- **Adding a `.tftest.hcl`**: every run block using an explicit
  `module { source = ... }` needs its own `provider "aws" {}` in the file plus
  `providers = { aws = aws }` on the block, or it fails with a confusing
  "Invalid provider configuration" that looks like a credentials problem.
- Terraform state is **local** — no backend configured yet.
- Never commit `accounts/*.tfvars` or anything under `.ignition/` (pull secret,
  kubeconfig, kubeadmin password). Both are gitignored; keep it that way.
