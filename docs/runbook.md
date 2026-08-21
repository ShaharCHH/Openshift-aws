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

### Gate: prove the AMI survives a reboot

Do this **before** launching a cluster on an AMI you have not already reboot-tested.
It takes about five minutes; skipping it costs about two hours.

```
./scripts/ami-build/verify-ami-reboot.sh -a horizon --ami <ami-id>
```

It boots one instance from the AMI (bastion must be up — it is the probe origin),
proves port 22 reachable, reboots, and proves it reachable again. **The second
check is the whole point.** A node that only works on its first boot looks
completely healthy right up until the MCO applies its first rendered config and
reboots every master at once — see `docs/architecture.md`, "Node networking is
configured twice".

## Phase 5 — Wait for bootstrap

Open an SSM port-forward to the bastion. `./scripts/tunnel.sh -a horizon` does
this and reconnects when the session times out; the underlying command is:

```
aws ssm start-session --target $(terraform output -raw bastion_instance_id) \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["6443"],"localPortNumber":["6443"]}'
```

Point the cluster's API name at that tunnel, in `/etc/hosts` on your machine:

```
127.0.0.1  api.horizon.ocp.internal
```

`api.` only — **not** `api-int`. Earlier versions of this file listed both, and
the internal name does nothing here: the installer's kubeconfig points at
`https://api.<cluster>.<base_domain>:6443`, and `api-int` is what *cluster
nodes* resolve (the MCS fetch on 22623), through the bastion's CoreDNS and its
own `/etc/hosts` — both written by the bastion userdata, neither involving your
machine.

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
Nothing to set up there: the bastion writes its own `/etc/hosts` entry for both
API names at boot (`templates/bastion-userdata.sh.tpl`), pointing them at
itself, and installs `oc` in the same pass.

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
console in a browser needs a tunnel on 443:

```
sudo -E ./scripts/tunnel.sh -a horizon --console
```

Local 443 is a privileged port, hence `sudo` — and `-E` specifically, or the
aws CLI loses `AWS_PROFILE` and your SSO cache and fails as if the credentials
were bad. It has to be 443 and not some convenient high port, because the
console redirects to the OAuth server by canonical hostname with no port in it.

**The `-E` that makes this work also has a sting, and it lands days later.**
Preserving `HOME` means the aws CLI running as root still reads *and writes*
your `~/.aws` — so any SSO token it refreshes is left there owned by `root`.
Nothing fails at the time. What fails is your next ordinary, non-sudo login:

```
aws: [ERROR]: [Errno 13] Permission denied:
  '/Users/<you>/.aws/sso/cache/706aa66a...json'
```

That filename is a hash of the start URL, so it points nowhere useful. Hit for
real on 21 Aug 2026, from a root-owned token written on 19 Aug. `tunnel.sh`
now hands ownership back on exit, and warns if it finds leftovers from an
earlier run. To clear them by hand — no sudo needed, the directories are yours:

```
find ~/.aws -user 0 -delete
```

**That redirect is also why two `/etc/hosts` entries are needed, not one.**
CoreDNS answers `*.apps` with a wildcard; `/etc/hosts` has no such thing, so
the console loads and then login fails on an unresolvable name:

```
127.0.0.1  console-openshift-console.apps.horizon.ocp.internal oauth-openshift.apps.horizon.ocp.internal
```

`tunnel.sh` checks for both and prints the line to add if either is missing.

---

## Phase 8 — Storage

The cluster has no working CSI driver and cannot have one — see
`docs/architecture.md`'s storage section for why every credential path is
closed. Storage is EFS spoken as plain NFS, with dynamic provisioning from
`nfs-subdir-external-provisioner`. Nothing in the cluster ever calls an AWS API.

The manifest ships with a literal `EFS_DNS_NAME` placeholder, because the
filesystem doesn't exist until Terraform has run. Substitute it from the
Terraform output at apply time:

```
efs_dns=$(cd terraform && terraform output -raw efs_dns_name)
sed "s/EFS_DNS_NAME/${efs_dns}/g" manifests/storage/nfs-provisioner.yaml | oc apply -f -
```

Use the DNS name, not the mount target IP. Both work, but the bastion's CoreDNS
forwards everything outside the cluster domain upstream (see the `Corefile` in
`templates/bastion-userdata.sh.tpl`), so nodes resolve
`fs-*.efs.<region>.amazonaws.com` fine — and the DNS name survives a mount
target being recreated with a different address.

Prove it works before moving on. A StorageClass that exists is not a
StorageClass that provisions:

```
oc get sc                       # efs-nfs, and it should be the only default
oc apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: scratch
spec:
  accessModes: [ReadWriteMany]
  storageClassName: efs-nfs
  resources:
    requests:
      storage: 1Gi
EOF
oc get pvc scratch              # must reach Bound
oc delete pvc scratch
```

---

## Phase 9 — Internal image registry

The registry is backed by a PVC on `efs-nfs`. Its native S3 backend is not an
option here for the same reason no CSI driver works: the registry runs as a pod,
and pods in this cluster cannot hold an AWS credential. See
`docs/architecture.md`.

```
oc apply -f manifests/registry/registry-pvc.yaml
oc get pvc image-registry-storage -n openshift-image-registry   # wait for Bound
```

**Then clear the S3 stanza — this is the step that trips people.** On AWS the
registry operator defaults `spec.storage` to `s3`, *and* it auto-detects a PVC
named `image-registry-storage` and fills in `spec.storage.pvc`. You end up with
both set, and the operator refuses to do anything:

```
Progressing: Unable to apply resources: unable to sync storage configuration:
exactly one storage type should be configured at the same time, got 2: [S3 PVC]
```

A merge patch adding `pvc` will not fix it, because it leaves `s3` in place.
Null the S3 key explicitly:

```
oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge \
  -p '{"spec":{"storage":{"s3":null}}}'
```

Confirm the rest of the config while you are there — on this cluster
`managementState: Managed`, `replicas: 2` and `rolloutStrategy: RollingUpdate`
were already correct by default. Two replicas are only safe because the volume
is RWX; with RWO you would need one replica and `Recreate`.

```
oc get co image-registry           # Available=True, Progressing=False, Degraded=False
oc get pods -n openshift-image-registry
```

### If builds fail with `InvalidOutputReference`

`Output image could not be resolved` after the registry has just come up means
the `openshift-controller-manager` is still holding the old, empty
`internalRegistryHostname`. The ImageStream will show an empty
`status.dockerImageRepository` at first and populate a minute or two later — but
the build controller does **not** pick it up on its own. Restart it:

```
oc delete pods -n openshift-controller-manager --all
```

Both were hit for real on 19 Aug 2026; neither error names the actual cause.

### Proving it works

An `Available=True` operator is not proof that the registry can store anything.
Do a real round-trip:

```
oc new-project registry-test
oc new-build --name=roundtrip --binary --strategy=docker
oc start-build roundtrip --from-dir=<dir with a Dockerfile> --follow
oc run pulltest --image=image-registry.openshift-image-registry.svc:5000/registry-test/roundtrip:latest \
  --restart=Never --command -- cat /test.txt
oc logs pulltest
oc delete project registry-test
```

And confirm the blobs really landed on EFS rather than somewhere ephemeral:

```
pod=$(oc get pods -n openshift-image-registry -l docker-registry=default -o name | head -1)
oc exec -n openshift-image-registry $pod -- sh -c \
  'df -h /registry; ls /registry/docker/registry/v2/repositories/'
```

The mount should read
`fs-*.efs.<region>.amazonaws.com:/openshift/openshift-image-registry-image-registry-storage`.

---

## Post-install cleanup

Three things the installer leaves in a state that needs a decision. None are
optional if you want `oc get clusteroperators` to come back clean.

**Remove the second default StorageClass.** The installer creates `gp3-csi` and
marks it default; `efs-nfs` is also default. Two defaults is undefined
behaviour — a PVC that names no class binds to whichever the API server picks.
`gp3-csi` cannot provision anything here (its driver has no credential), so the
annotation has to come off it, not off `efs-nfs`:

```
oc patch storageclass gp3-csi -p \
  '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
```

**The `storage` operator cannot simply be switched off — do not use
`managementState: Removed` on it.** That instruction circulated in an earlier
handoff and is wrong. The operator rejects the value and reports a *second*
degraded condition on top of the one you were trying to clear:

```
ManagementStateDegraded: Removed is not supported for storage operator
```

Verified directly on this cluster. If it has already been set, put it back:

```
oc patch storage cluster --type=merge -p '{"spec":{"managementState":"Managed"}}'
```

The operator is Degraded because the EBS CSI *controller* can never start here
— it runs on the pod network and cannot reach IMDS for a credential (see
`docs/architecture.md`). The driver's own object is the supported lever:

```
oc get clustercsidriver ebs.csi.aws.com -o jsonpath='{.spec.managementState}'
oc patch clustercsidriver ebs.csi.aws.com --type=merge \
  -p '{"spec":{"managementState":"Removed"}}'
```

**Untested as of 19 Aug 2026** — the storage operator refuses `Removed` for
itself, and whether it accepts it for a driver it considers required on AWS has
not been confirmed. Verify the result rather than assuming it worked. If it is
also refused, the honest position is that `storage` stays Degraded on this
platform and belongs in the known-inert list below, not that it can be cleared.

**Confirm `control-plane-machine-set` is inertly Degraded** — do not assume it,
and be aware the obvious explanation is the wrong one. It is tempting to say
"UPI masters have no `Machine` objects, so of course the CPMS is unhappy."
Check, and you find they do have them:

```
oc get machines.machine.openshift.io -n openshift-machine-api
oc get machine.machine.openshift.io <name> -n openshift-machine-api -o jsonpath='{.status}' | jq
```

The three master `Machine` objects exist, created by the installer, sitting at
an empty `phase`. The real reason is on the `InstanceExists` condition:

```
failed to create aws client: aws credentials secret
openshift-machine-api/aws-cloud-credentials ... not found
```

This is the **same missing-cloud-credential wall** as the CSI drivers, the
registry's S3 backend and IMDS-from-pods — not a separate UPI quirk. The
machine controller cannot talk to EC2, so it can never mark a `Machine`
Running, so the CPMS reports `No ready control plane machines found`.

It is inert *today* because the controller cannot act at all. Worth
remembering that the CPMS is `Active` with 3 unavailable replicas: if a working
cloud credential ever appeared in this cluster, that controller would become
able to act on control-plane machines it currently considers unavailable.

---

## Day-2 operations

**Reaching the cluster at all** — there is no public endpoint, so every `oc`
call and every browser tab goes through an SSM port-forward to the bastion:

```
./scripts/tunnel.sh -a horizon              # 6443, for oc/kubectl
sudo -E ./scripts/tunnel.sh -a horizon --console   # 443, for the web console
```

One session forwards one port, so the console tunnel is a second terminal. The
script reads `accounts/<alias>.tfvars` directly — no terraform state, any
working directory — checks the `/etc/hosts` entries the tunnel needs before
binding anything, and reconnects when the session hits its idle timeout
(see the Troubleshooting row below for why that matters). Ctrl-C closes it.

Heavy or long-running work is still better done from the bastion itself, which
reaches the API over the VPC with no tunnel in the path.

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
| Every node goes `NotReady` at once, `Kubelet stopped posting node status`, all within seconds of each other | The nodes rebooted (almost certainly an MCO rollout) and came back with no IP. Check the console banner for `ens5:` with nothing after it. The kernel args only configure the initramfs; the real root needs the NetworkManager keyfile from `templates/node-network.nmconnection.tpl`. Note `:6443` can stay open through this — CRI-O keeps existing containers running even with kubelet down, so an open port is not proof of a healthy node |
| Nodes stay `NotReady` forever, `aws-cloud-controller-manager` in CrashLoopBackOff | Missing `cluster_infra_id` tag, or a missing EC2 permission on the master role. Read the pod's actual logs — it names the exact denied action |
| `oc` reports `TLS handshake timeout` while `wait-for` runs fine | SSM tunnel contention. Run `oc` from the bastion |
| `ingress` stuck `Available=False`, router Service at `EXTERNAL-IP <pending>`, operator logging `SyncLoadBalancerFailed` | The default IngressController was not pinned to `HostNetwork` before `create ignition-configs`. It is trying to build an SCP-denied ELB. `endpointPublishingStrategy` is immutable once the object exists, so this cannot be patched — the IngressController has to be deleted and recreated. Cheaper to regenerate ignition and reinstall |
| Objects wedged in `Terminating` under `openshift-ingress` | Same cause as above: the load-balancer Service holds a finalizer that can never complete, because the ELB it refers to was never created |
| A PVC binds to an unexpected class, or sits `Pending` with no provisioner named | Two StorageClasses are both marked default — see Post-install cleanup. `oc get sc` shows more than one `(default)` |
| `oc` suddenly fails with `connection refused` to `127.0.0.1:6443` after a quiet spell | The SSM port-forward session timed out: `Your session timed out due to inactivity and has been terminated`. It closes cleanly (exit 0), so nothing looks broken until the next command. Restart the port-forward; long-running work through the tunnel should keep it busy or expect to reconnect. `./scripts/tunnel.sh` rides through this — it reconnects and logs each reconnect, so the tunnel dying stops being invisible |
| `aws sso login` fails with `[Errno 13] Permission denied` on a hash-named file under `~/.aws/sso/cache/` | An earlier `sudo -E` run (the console tunnel on 443) left a root-owned token in your own `~/.aws`. The filename is a hash of the start URL and names nothing actionable. `find ~/.aws -user 0 -delete`, then log in again — no sudo needed, the directories are yours. `tunnel.sh` restores ownership on exit now, and warns about leftovers |

When a pod is in `CrashLoopBackOff` and you've just fixed its cause,
`oc delete pod -l <selector>` skips the growing backoff timer instead of
waiting it out. Safe for anything Deployment-managed.

---

## Current state

As of **19 August 2026** this design reaches a working cluster and keeps it:

- `bootstrap-complete` in 4m20s (every attempt before 18 Aug timed out at 45
  minutes), 3/3 masters `Ready`, console reachable.
- **A hibernate/wake cycle has now been survived for real.** This was the open
  risk in the previous handoff — the cluster had never been stopped and started
  again. All three masters came back with their addresses intact, so the
  NetworkManager keyfile fix holds beyond the MCO reboot it was written for.
- Dynamic RWX storage on `efs-nfs`, re-verified after that reboot.
- Internal image registry working, PVC-backed, with a full build → push → pull
  round-trip verified.

The ClusterIP problem previously recorded here — operators unable to reach the
`kubernetes` Service ClusterIP at `172.30.0.1:443` from inside a pod, leaving
masters without their etcd/kube-apiserver static pod manifests — was **not** an
OVN service-load-balancing fault. It was two missing security-group rules
(`bootstrap_api_from_master` and `master_api_from_master`). The DNAT'd packet
leaves the node directly rather than going via the bastion, so no
bastion-sourced rule covered it. Both now exist in `modules/security-groups`.

### Known-inert, do not chase

- **`control-plane-machine-set` Degraded** is expected here, but *not* for the
  reason usually given. The masters do have `Machine` objects; the machine
  controller simply has no cloud credential to reconcile them with. Same root
  cause as everything else in this cluster. Confirm the condition message
  rather than assuming it — see Post-install cleanup for what to check.
- **`network` permanently `Progressing`.** Its
  `cloud-network-config-controller` pod is stuck in `ContainerCreating` on
  `secret "cloud-credentials" not found` — the credential wall again. The
  operator stays `Available=True`/`Degraded=False`, and the controller only
  drives optional cloud networking features this design does not use.
- **`storage` Degraded.** The EBS CSI controller can never start here, and the
  storage operator refuses `managementState: Removed` for itself. Unless the
  `ClusterCSIDriver`-level removal in Post-install cleanup turns out to work,
  this operator stays Degraded on this platform. Treat it as inert; do not keep
  patching at it.
