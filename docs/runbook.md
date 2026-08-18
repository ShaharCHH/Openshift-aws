# Runbook: deploying a cluster

The ordered command sequence for standing up an OpenShift UPI cluster with
this repo. `docs/architecture.md` explains *why* the design looks like this;
this file is just *what to run, in what order*. Examples use account alias
`horizon` — substitute your own.

## Before you start

On the operator's machine:

- `terraform` (>= 1.9), `aws`, `jq`, `oc`, and `openshift-install` (matching
  the OCP version you're deploying — 4.22 here) on `$PATH`
- The AWS Session Manager plugin, for the SSM tunnel later
- A Red Hat pull secret (`~/pull-secret.json`) and an SSH public key
- Valid credentials for the target account:
  ```
  aws sso login --profile Workload-Admin-PS-342831714456
  export AWS_PROFILE=Workload-Admin-PS-342831714456
  ```

In the repo:

```
cp accounts/example.tfvars.sample accounts/horizon.tfvars
# fill in aws_region / existing_vpc_id / existing_private_subnet_id /
# account_alias / cluster_name / base_domain
```

`accounts/*.tfvars` is gitignored — it holds per-client infrastructure IDs.

## The ordering constraint

The phases below are not interchangeable, because each feeds the next:

```
bastion apply ──> AMI build ──> ignition generation ──> full apply
   (S3 bucket,      (needs the       (needs the S3         (needs the AMI id,
    bastion IP)      bastion IP        bucket name and       the MCS CA, and
                     as a kernel       install_config_       the infra ID)
                     argument)         inputs output)
```

Most importantly, **the AMI has to be built after the bastion exists**, not
before. The bastion's private IP gets baked into the AMI as a
`nameserver=` kernel argument — masters can't resolve
`api-int.<cluster>.<domain>` at Ignition-fetch time otherwise, and that's a
hard failure with a confusing signature (see Troubleshooting).
`build-custom-ami.sh` reads that IP from `terraform output` automatically,
or accepts `--dns <ip>` if you need to build ahead of the bastion.

---

## Phase 0 — Validate the account (new accounts only)

```
cd preflight && terraform init
../scripts/preflight/run-all.sh -a horizon
```

Exit code 0 means every capability UPI needs works and every operation we
deliberately avoid is still blocked. Anything else is a real finding — see
`docs/preflight.md` for how to read the report, and `docs/scp-blockers.md`
for what each probe is checking and why.

Skip this on an account you've already validated.

## Phase 1 — Bastion, IAM, S3, security groups

Both phase toggles default to `false`, so a plain apply brings up the
supporting infrastructure without any cluster nodes:

```
cd terraform
terraform init
terraform apply -var-file=../accounts/horizon.tfvars
```

This creates the S3 bucket, the four IAM roles, the security groups, and the
bastion itself (CoreDNS + HAProxy + the ignition HTTP server on :8080, all as
containers). HAProxy starts with empty backend lists — expected at this
stage, since nothing exists to balance yet.

Confirm the bastion registered with SSM before moving on:

```
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$(terraform output -raw bastion_instance_id)" \
  --query 'InstanceInformationList[0].PingStatus' --output text
```

`Online` means its userdata ran and the SSM agent is up. If it never comes
online, the bastion never finished bootstrapping and nothing downstream will
work.

## Phase 2 — Build the RHCOS AMI

```
cd ..
./scripts/ami-build/build-custom-ami.sh -a horizon
```

Streams Red Hat's raw RHCOS image onto a self-owned EBS volume via a helper
instance, snapshots it, and registers an account-owned AMI — bypassing the
vmimport pipeline entirely (`docs/scp-blockers.md` rows 5 and 6). It also
patches three things into the AMI's GRUB boot entry, all of which are
load-bearing:

- `ignition.platform.id=aws` — the `metal` image doesn't know it's on EC2
- `console=ttyS0,115200n8 console=tty0` — without this there's no serial
  console output at all, and debugging a failed boot becomes guesswork
- `ip=dhcp nameserver=<bastion-ip>` — the DNS fix. **`nameserver=` without
  `ip=dhcp` hangs dracut before any console output**, confirmed for real on
  every node including bootstrap. Never separate them.

The script is idempotent: if the AMI already exists it prints the id and
exits. Pass `--force` to rebuild. It prints the AMI id on stdout:

```
export TF_VAR_rhcos_ami_id=$(./scripts/ami-build/build-custom-ami.sh -a horizon)
```

Takes roughly 10–15 minutes on a fresh build.

## Phase 3 — Generate ignition

> **Redo this phase in full on every rebuild.** `openshift-install create
> manifests` mints a fresh cluster CA and a fresh infraID *every single run*,
> so all three `-var` values below change each time. Reusing yesterday's
> produces an x509 "certificate signed by unknown authority" loop on the
> masters that looks nothing like a stale-value problem.

```
./scripts/ignition/render-install-config.sh -a horizon \
  --pull-secret ~/pull-secret.json \
  --ssh-key ~/.ssh/id_rsa.pub

./scripts/ignition/generate-ignition.sh -a horizon

export TF_VAR_mcs_ca_data_url=$(./scripts/ignition/extract-mcs-ca.sh -a horizon)
export TF_VAR_cluster_infra_id=$(./scripts/ignition/extract-infra-id.sh -a horizon)
```

What each step does:

1. **`render-install-config.sh`** builds `install-config.yaml` from
   `terraform output -json install_config_inputs` — region, subnet IDs,
   machine CIDR — so no network values are ever hand-typed. Compact topology
   (`compute.replicas: 0`, masters schedulable), `publish: Internal`,
   `credentialsMode: Manual`.
2. **`generate-ignition.sh`** runs `create manifests` then
   `create ignition-configs`, and uploads `bootstrap.ign` and `master.ign` to
   `s3://<bucket>/ignition/`. `worker.ign` is generated but never uploaded —
   there are no worker nodes in this topology.
3. **`extract-mcs-ca.sh`** pulls the cluster CA out of `master.ign` so it can
   be embedded in the *wrapper* ignition Terraform builds. This is not
   optional: relying on `master.ign`'s own self-referential CA declaration
   fails, because our design merges it through an extra hop that a normal
   install never exercises.
4. **`extract-infra-id.sh`** reads `infraID` from `metadata.json`, used to tag
   instances `kubernetes.io/cluster/<infraID>=owned`. Without that tag the
   in-cluster cloud-controller-manager fails with "AWS cloud failed to find
   ClusterID", no node ever loses its `uninitialized` taint, and nothing
   schedules — including the CNI.

Output lands in `.ignition/horizon/` (gitignored — it contains the pull
secret, kubeconfig, and kubeadmin password).

The bastion polls S3 every 60 seconds, so the new ignition files reach it
without a further apply.

**Bootstrap ignition certificates are valid for 24 hours.** If more than a
day passes between this phase and a successful bootstrap, regenerate.

## Phase 4 — Launch bootstrap and masters

```
cd terraform
terraform apply -var-file=../accounts/horizon.tfvars \
  -var="masters_enabled=true" \
  -var="bootstrap_enabled=true"
```

The three `TF_VAR_`-exported values from phases 2 and 3 are picked up
automatically.

> **Every subsequent apply must carry all of these values too.** They live in
> the environment rather than tfvars on purpose — tfvars history should
> reflect steady-state config, not transient bring-up state — but dropping
> `rhcos_ami_id` while `masters_enabled=true` is still set will fail the
> plan, and dropping `cluster_infra_id` silently removes the cluster tag and
> re-breaks the cloud-controller-manager. Keep the exports for the whole
> session.

Terraform also re-renders `haproxy.cfg` with bootstrap + all three masters as
API/MCS backends, uploads it to S3, and pushes it onto the bastion over SSM
with a validate-then-`SIGHUP` reload. That `local-exec` waits on the SSM
command, so a failed reload fails the apply rather than leaving stale config
running.

## Phase 5 — Wait for bootstrap

Open an SSM port-forward to the bastion (no wrapper script exists yet):

```
aws ssm start-session --target $(terraform output -raw bastion_instance_id) \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["6443"],"localPortNumber":["6443"]}'
```

Point the cluster's API name at that tunnel, in `/etc/hosts` on your machine:

```
127.0.0.1  api.horizon.ocp.internal api-int.horizon.ocp.internal
```

Then:

```
openshift-install wait-for bootstrap-complete --dir ../.ignition/horizon --log-level debug
```

Expect roughly 20 minutes for the API to answer and up to 45 for bootstrap to
finish. While waiting, port 22623 opening on the masters is the signal that
the MCS fetch chain is working — that's the step that has historically
failed.

**Don't run `oc` through the same tunnel concurrently with `wait-for`.** The
tunnel handles one heavy consumer well and two badly; you'll get
`TLS handshake timeout` on the `oc` side while `wait-for` keeps working, which
reads like a cluster problem and isn't. Run `oc` from the bastion instead —
it reaches the API directly over the VPC network with no tunnel involved.
The bastion needs its own `/etc/hosts` entry for the API names, same as above.

## Phase 6 — Drop bootstrap

Once `wait-for bootstrap-complete` returns, the masters run the real control
plane and bootstrap is dead weight:

```
terraform apply -var-file=../accounts/horizon.tfvars \
  -var="masters_enabled=true" \
  -var="bootstrap_enabled=false"
```

HAProxy's backend list updates automatically — the `haproxy-config` module
notices bootstrap left `api_mcs_backends` and reloads the bastion in place.
No instance replacement, no reboot.

## Phase 7 — Finish and access

```
openshift-install wait-for install-complete --dir ../.ignition/horizon --log-level debug

export KUBECONFIG=../.ignition/horizon/auth/kubeconfig
oc get clusteroperators
```

Every operator reporting `Available=True` is the finish line. Console
credentials are in `.ignition/horizon/auth/kubeadmin-password`; reaching the
console in a browser needs a tunnel on 443 to
`console-openshift-console.apps.horizon.ocp.internal` plus the matching
`/etc/hosts` entry.

---

## Day-2 operations

**Pausing between work sessions** — stops instances, pausing compute
billing. EBS volumes bill regardless, so this is for gaps of days, not
weeks; for anything longer, destroy and rebuild:

```
./scripts/hibernate.sh -a horizon
./scripts/wake.sh -a horizon
```

`wake.sh` waits for the bastion's SSM agent to come back before returning,
since CoreDNS and HAProxy need to be up before masters can rejoin cleanly.
Both scripts find instances by the `Project=openshift-upi` +
`AccountAlias=<alias>` default tags.

**Tearing the cluster down but keeping the bastion** — useful between
rebuild attempts:

```
terraform apply -var-file=../accounts/horizon.tfvars \
  -var="masters_enabled=false" -var="bootstrap_enabled=false"
```

**Full teardown:** `terraform destroy -var-file=../accounts/horizon.tfvars`.
The custom AMI and its snapshot are not Terraform-managed and survive —
deregister them by hand if you want them gone.

---

## Troubleshooting

**Don't trust `aws ec2 get-console-output`.** It has been unreliable and
laggy enough to send this project down two dead ends — it showed nothing at
all for an instance that was demonstrably alive and actively retrying at 500+
seconds of uptime. Console silence is not evidence of a hang. Use the EC2
Serial Console for live output:

```
aws ec2 enable-serial-console-access          # once, account-level
aws ec2-instance-connect send-serial-console-ssh-public-key ...
ssh <instance-id>.port0@ec2-serial-console.il-central-1.api.aws
```

Two traps worth knowing before you need this:

- **The region endpoint format is non-standard here.** `il-central-1` uses
  `ec2-serial-console.<region>.api.aws`, not the
  `serial-console.ec2-instance-connect.<region>.amazonaws.com` form most
  documentation shows.
- **The pushed SSH key is valid for about 60 seconds**, and anything between
  the push and the `ssh` call can burn the window. Push and connect
  back-to-back. Don't use a named FIFO to hold stdin open — opening one for
  read blocks until a writer appears, stalling `ssh` before it starts. Use an
  anonymous pipe (`sleep 90 | ssh ...`).

**Use port reachability as the real signal.** Checked from the bastion over
SSM: 6443 and 22623 opening on a node is trustworthy where console output
isn't. Give it 10+ minutes before concluding a boot has failed — that
patience has proven necessary.

**Failures seen for real, and what each one means:**

| Symptom | Cause |
|---|---|
| `lookup api-int...: no such host` in Ignition retries | The AMI is missing its `nameserver=` kernel arg, or was built against a stale bastion IP |
| Boot hangs with zero console output on every node | `nameserver=` was passed without `ip=dhcp` |
| `x509: certificate signed by unknown authority` retrying every 5s | `mcs_ca_data_url` is stale — regenerate ignition and re-extract |
| `GET error: ... EOF` on port 22623 | DNS and TCP are fine; HAProxy's MCS backend list is empty. Normal if no bootstrap is running |
| Nodes in emergency mode ~90s after launch, `failed to fetch config: resource not found` | The bastion's ignition server answered 404 — it was replaced in the same apply that created the nodes, so it was still empty when they booted. EC2 status checks read `ok`/`ok` throughout. Replace the nodes once the bastion is serving; check `ls /var/ignition-serve/ignition/` on it first |
| Nodes stay `NotReady` forever, `aws-cloud-controller-manager` in CrashLoopBackOff | Missing `cluster_infra_id` tag, or a missing EC2 permission on the master role. Read the pod's actual logs — it names the exact denied action |
| `oc` reports `TLS handshake timeout` while `wait-for` runs fine | SSM tunnel contention. Run `oc` from the bastion |

When a pod is in `CrashLoopBackOff` and you've just fixed its cause,
`oc delete pod -l <selector>` skips the growing backoff timer instead of
waiting it out. Safe for anything Deployment-managed.

---

## Known unresolved

As of the last session, `wait-for bootstrap-complete` still does not
complete. Nodes reach `Ready` with CNI up, but cluster operators stall:
masters never receive their etcd/kube-apiserver static pod manifests
(`/etc/kubernetes/manifests/` holds only `criometricsproxy.yaml`), because
CVO is stuck behind operators that cannot reach the in-cluster `kubernetes`
Service ClusterIP at `172.30.0.1:443` from inside a pod — even though
external API access through HAProxy works throughout. The Service's
Endpoints object does list a real backend, so the open question is whether
OVN-Kubernetes' service load-balancing for that ClusterIP is functioning.

Next diagnostic step:

```
oc debug node/<name> -- chroot /host curl -k https://172.30.0.1:443/healthz
```
