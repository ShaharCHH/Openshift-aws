# Architecture

This file explains *why* the design looks the way it does. For the
ordered command sequence to actually deploy a cluster, see
`docs/runbook.md`.

## Why this looks different from a standard OpenShift UPI install

This account's SCP blocks Route 53, ELB/NLB creation, Elastic IPs, launching
or copying any AMI the account doesn't itself own, the vmimport service
role's internal snapshot-copy step, and — with the widest consequences of any
of them — both ways of issuing an IAM identity to an in-cluster component
(`iam:CreateUser` and `iam:CreateOpenIDConnectProvider`). See
`docs/scp-blockers.md` for the full, individually-verified list. Every departure from the "normal" AWS UPI
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
  nodes. It is started by `sync-config.sh` *after* the first successful
  S3 pull, never by the day-0 userdata directly: Ignition retries a refused
  connection but treats HTTP 404 as fatal, so a server listening on an empty
  directory kills every node booting in that window. Keeping the port closed
  until the files are on disk turns that window into connection-refused,
  which nodes survive.

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

## Node networking is configured twice, in two different places

This looks redundant and isn't. A cluster node needs working networking at two
moments that share nothing:

**In the initramfs**, before a root filesystem exists, so Ignition can resolve
`api-int.<cluster>.<base_domain>` for its `config.merge` fetch to the Machine
Config Server. Nothing on disk exists yet, so the only vehicle is a kernel
argument: `ip=dhcp nameserver=<bastion-ip>`, patched into the AMI's GRUB entry by
`scripts/ami-build/build-custom-ami.sh`. (`nameserver=` without `ip=dhcp` hangs
dracut before any console output — always pair them.)

**On the real root**, for every boot from then on. This is the part that is easy
to miss, because the first boot appears to work without it: the initrd hands its
connection over to NetworkManager, and the node comes up fine. But on RHEL 9,
having network configuration on the kernel command line changes how NetworkManager
behaves on the real root, and with no persistent connection profile on disk, every
**subsequent** boot comes up with the interface unconfigured.

That was found the expensive way. All three masters rebooted together when the MCO
applied its first rendered config, and came back with no address:

```
ens5:
Ignition: ran on 2026/08/18 09:17:45 UTC (at least 2 boots ago)
```

All three kubelets stopped posting within two seconds of each other. AWS still held
every private IP on an attached, in-use ENI — so the VPC would have handed out the
leases; the failure was entirely inside the guest. Since the MCO reboots nodes as
routine maintenance, a cluster missing this second half cannot survive its own
first config rollout, and every bring-up before that point looks perfectly healthy.

The fix is `terraform/templates/node-network.nmconnection.tpl`, a NetworkManager
keyfile delivered through the **wrapper ignition** (`modules/control-plane` and
`modules/bootstrap`, mode 0600 — NM ignores world-readable keyfiles). It is
deliberately not baked into the AMI: `build-custom-ami.sh` only ever mounts the
`boot` partition, and writing into RHCOS's ostree `/etc` means new code plus merge
semantics that can silently discard a raw file drop. It is deliberately not a
MachineConfig either: that would work for masters but not for bootstrap, which *is*
the Machine Config Server and never fetches from one.

Note this is the opposite of the constraint described below under "The mechanism,
and why it changed" — a MachineConfig cannot fix the *initramfs* problem, because
it arrives behind the very fetch it would unblock. It can, however, fix the real
root, which is why the two halves need two different mechanisms.

`scripts/ami-build/verify-ami-reboot.sh` is the acceptance gate: it boots an
instance from an AMI, proves it reachable, reboots it, and proves it reachable
again. First-boot success alone proves nothing.

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
   manifests and consumes the input file. No manifest patching happens here:
   a standard UPI install would set `mastersSchedulable: false` in
   `manifests/cluster-scheduler-02-config.yml` at this point, but this is a
   compact topology (`compute.replicas: 0`), where the installer already
   leaves masters schedulable and they're meant to carry ordinary workloads
   and ingress themselves.
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

## Ingress publishes on the host network, and that is an install-time decision

On AWS the installer's default `endpointPublishingStrategy` is
`LoadBalancerService`, which makes the ingress operator provision a Classic
ELB — the operation this account's SCP blocks outright (`docs/scp-blockers.md`
row 4), and the whole reason HAProxy runs on the bastion at all. Left at the
default, ingress never comes up: the operator reports `SyncLoadBalancerFailed`
forever, the router Service sits at `EXTERNAL-IP <pending>`, and the `ingress`
clusteroperator stays `Available=False` — which alone is enough to fail
`wait-for install-complete`. Worse, the objects it leaves behind deadlock on a
finalizer that can never complete, so they sit in `Terminating` indefinitely.

`HostNetwork` makes the router pods bind each node's own `:80`/`:443` instead,
which is exactly what Terraform's `haproxy_config` ingress backends already
point at (master IPs, in this compact topology).

**The timing is the part that matters.** `endpointPublishingStrategy` is
immutable once the IngressController exists — fixing it after the fact means
deleting and recreating the IngressController by hand. So it is written as a
manifest by `scripts/ignition/generate-ignition.sh` in the one window where the
manifests are still editable: between `create manifests` and
`create ignition-configs`. This is the same window, and the same reasoning, as
any other install-time-only override.

## The cluster is its own CA, and the operator's machine has to be told so

There is no public CA anywhere in this design and there cannot be one: no
Route 53, no ELB, no public endpoint at all (`docs/scp-blockers.md` rows 1, 3,
4). Every certificate the cluster serves is signed by a root it minted for
itself, and nothing outside the cluster has ever heard of that root —
`scripts/trust-cluster-ca.sh` is the fix, installed into the operator's own
machine trust store, once, per machine.

`oc` is unaffected by any of this **for calls that use the admin kubeconfig
directly against `:6443`**. `openshift-install`'s admin kubeconfig embeds the
API's CA inline as `certificate-authority-data`, so `oc get`/`oc apply`/etc.
verify the tunnel's TLS correctly with no setup. The problem is everything
else that instead consults the OS trust store — a browser hitting the
console, `curl`, anything that isn't `oc` talking straight to `:6443` — **and,
once an identity provider exists, `oc login` itself**: see "Cluster login:
htpasswd" below for why that command specifically needs the ingress CA too.

Because of that, `trust-cluster-ca.sh` cannot be the fix for an `oc`-side x509
error, no matter how it's run — `oc` never opens the keychain. If `oc get no`
fails with `certificate signed by unknown authority`, the merged
`~/.kube/config` (`scripts/update-kubeconfig.sh`) is carrying a **previous
cluster generation's** `certificate-authority-data`: a rebuild mints a fresh
CA under an identical CN (see below), so an already-merged kubeconfig goes
stale exactly the same way an already-trusted keychain entry does, just for a
different tool. Re-running `update-kubeconfig.sh` after every rebuild is what
actually clears it — confirmed for real 27 Aug 2026, where a stale merge from
before a rebuild produced this loop for over a week despite the keychain
being correctly populated the whole time.

There are two roots to install, not one, because the API and the ingress
router are signed by two entirely separate CAs with no relationship to each
other:

| Endpoint | Leaf CN | Root CA | Where it lives |
|---|---|---|---|
| `api.<cluster>.<domain>:6443` | `api.<cluster>.<domain>` | `kube-apiserver-lb-signer` | `.ignition/<alias>/auth/kubeconfig`, offline |
| `*.apps.<cluster>.<domain>` | `*.apps.<cluster>.<domain>` | `ingress-operator@<unix-ts>` | `cm/default-ingress-cert` in `openshift-config-managed`, cluster-only |

Two things make extracting these two roots less trivial than "copy the PEM
out of a file":

- **The kubeconfig's CA bundle holds three self-signed roots, not one** —
  `kube-apiserver-localhost-signer`, `kube-apiserver-service-network-signer`,
  and `kube-apiserver-lb-signer`. Only the `lb-signer` one signs anything the
  operator's machine actually talks to; the other two exist for in-cluster
  traffic this machine never sees. Trusting all three machine-wide would work
  but widens what's trusted for no benefit — `trust-cluster-ca.sh` picks out
  the one that matters by subject.
- **`default-ingress-cert`'s bundle is the wildcard leaf, then its root** —
  in that order. The leaf is not what belongs in a trust store: it's a server
  cert with its own, shorter expiry, not a CA. Only the self-signed member of
  the bundle (subject == issuer) goes in.

`create manifests` mints a fresh cluster CA on every rebuild (see "Regenerate
ignition in full on every rebuild" in `CLAUDE.md`), so re-running the install
produces a *different* `kube-apiserver-lb-signer` cert under the identical
subject — the CN is a constant across every cluster this repo ever builds.
There is nothing cluster-specific inside it to key a cleanup off of, which is
why `trust-cluster-ca.sh` has no state file: `--uninstall` re-derives the
current fingerprints from the same live sources rather than remembering what
it installed last time, and on install it surfaces (never auto-removes) any
other cert already trusted under that same CN — almost certainly a stale root
left by an earlier rebuild.

When the authenticated sources aren't available — no kubeconfig yet, or the
cluster unreachable through the tunnel — the script falls back to scraping the
TLS chain served on the tunnel's local port and trusts it on first use, but
only after checking the scraped root is actually self-signed, that the leaf
served alongside it verifies against it, and that the leaf's SAN covers the
name being trusted. That fallback exists for bootstrap-adjacent moments (no
merged kubeconfig yet) more than routine use — the authenticated sources are
preferred whenever they're reachable.

### A third CA exists, and it is deliberately not trusted here

Every pod-to-pod certificate in the cluster — including the image registry's
own serving cert — is signed by a *third* root, the service-ca operator's
`openshift-service-serving-signer@<unix-ts>`. This is not an oversight in the
table above; it is the reason the registry's external route is `reencrypt`
and not `passthrough`.

Passthrough hands the client the pod's own cert unmodified, which means the
service-ca root, which means a cert whose SAN is scoped to
`image-registry.openshift-image-registry.svc[.cluster.local]` — an in-cluster
service name, never a route hostname. Trusting that root machine-wide would
not fix external access: the SAN still would not cover
`registry-....apps.<cluster>.<domain>`, so hostname verification would still
fail. It was tried for real, on the running cluster, on 26 Aug 2026, and
failed exactly that way.

`reencrypt` sidesteps the problem instead of solving it: the router
terminates the client-facing side itself and re-signs with the ingress
wildcard, so the service-ca signer never reaches the client at all. The
router already trusts the service-ca bundle on the *backend* side by default
(`DEFAULT_DESTINATION_CA_PATH=/var/run/configmaps/service-ca/service-ca.crt`
on `deploy/router-default`), so `manifests/registry/registry-route.yaml`
needs no `destinationCACertificate` of its own. This is also why the service
CA is absent from the table above and from `trust-cluster-ca.sh` — trusting
it on the client side would be trusting a CA for names it was never issued
for.

## Cluster login: htpasswd, because no identity provider here can hold a credential

Before this, the only human login was the shared `kubeadmin` password: one
bootstrap credential with cluster-admin, no per-person identity, no way to
revoke one operator without rotating for everyone. OpenShift treats it as
temporary and expects a real identity provider in its place.

**HTPasswd was chosen by elimination, not preference.** Every cloud-IAM-backed
identity provider needs the cluster to hold or broker an AWS credential, and
this cluster cannot — that is the same credential wall documented above and
in `CLAUDE.md`: `iam:CreateUser` and `iam:CreateOpenIDConnectProvider` are
SCP-denied, and pods on the OVN pod network cannot reach IMDS to borrow the
node's identity either. External SSO (LDAP, an org's own OIDC provider) needs
an egress path this cluster does not have. HTPasswd needs neither: it is a
password file the cluster stores itself. If a future reader is tempted to
"upgrade" this to something IdP-shaped, the credential wall is still there —
check `docs/scp-blockers.md` before assuming it has moved.

`scripts/manage-cluster-users.sh` is the tool. **The cluster's `htpass-secret`
(namespace `openshift-config`) is the source of truth; the local cache at
`.ignition/<alias>/auth/htpasswd` is disposable** — bcrypt is one-way, so the
local file holds no information the secret doesn't, and every mutating run
pulls from the cluster first rather than trusting what's on disk.

### Why there is no `manifests/auth/oauth-htpasswd.yaml`

Every other manifest in this repo (`manifests/registry/*.yaml`, etc.) is
something safe to `oc apply` repeatedly: it creates or fully owns an object.
`OAuth/cluster` fails that pattern on both counts:

- It **always already exists** — created by the cluster-version operator,
  owned by `ClusterVersion`, annotated `release.openshift.io/create-only:
  "true"`. The operation needed here is *mutate a field of a foreign object*,
  not *create one*.
- **`spec.identityProviders` is `x-kubernetes-list-type: atomic`** (verified
  by reading the installed CRD). Atomic means the list is replaced as a
  whole on any write to it — there is no per-element merge. Both of the
  obvious ways to change it destroy every *other* identity provider with no
  error and no diff:
  - `oc apply -f <a full OAuth object>` replaces the list.
  - `oc patch --type=merge -p '{"spec":{"identityProviders":[...]}}'` — a
    JSON merge patch replaces arrays wholesale too. Also replaces the list.

  A checked-in manifest would sit in the runbook right beside manifests that
  *are* safe to re-apply, and would silently delete a future second identity
  provider (LDAP, say) the day someone adds one. So the script does a
  read-modify-write instead: read the current list with `jq`, replace only
  the entry named `htpasswd` in place (or append it, first time), write the
  full list back — and skip the patch entirely when the result is
  byte-identical, since even a no-op patch bumps `resourceVersion` and rolls
  all three `oauth-openshift` pods for nothing.

**The identity provider's name is permanent once used.** It is baked into
every `Identity` object as `<idp-name>:<username>` — renaming it later
orphans every existing user's Identity at once, at the same time. The name is
plain `htpasswd`; it is also what renders as the console's login button
label, so it doubles as user-facing text.

### Deletion is four objects, not one

`User` and `Identity` are cluster-scoped, with no owner reference and nothing
that garbage-collects them. Removing a line from `htpass-secret` removes only
the *ability to authenticate* — three other things can still be true after
that:

- **Live tokens keep working.** OAuth access tokens last 24h. Stop at the
  htpasswd line and a removed user's open console tab and `oc` session keep
  working until that token expires on its own.
- **A stale `Identity` breaks the *next* login, not the removed user's
  current one** — it points at a `User` UID that may no longer resolve
  cleanly, and the failure looks like nothing in `oc get co`.
- **A dangling `cluster-admin` binding is the dangerous one.** RBAC subjects
  are plain strings — a `ClusterRoleBinding` binds the literal name `alice`,
  not a stable identity. Delete Alice, leave the binding, and hand the
  username `alice` to a different person six months later: she is silently
  cluster-admin on first login.

`--delete` therefore removes the htpasswd line, the `Identity`, the `User`,
every live `oauthaccesstoken`/`oauthauthorizetoken` naming that user, and (by
default; `--keep-rbac` opts out) any `cluster-admin` binding naming them —
**in that order**, secret first so no new login can start with the old
password while the rest runs.

Deleting the `User` is what actually revokes existing sessions — the token
authenticator resolves a token's `userName` to a `User` object and checks its
UID, so a token surviving that lookup is what "logged in" means. This is not
literally synchronous: there's a short positive-authentication cache in
front of that check. Measured live against this cluster: a token was still
accepted 10 seconds after the delete command completed, and rejected by 25
seconds. Fast — nothing like the up-to-24h exposure of stopping at the
htpasswd line alone — but a real, non-zero window, worth knowing about
before treating "the delete command returned" as "access ended this
instant."

### Rollout: every mutation rolls all three `oauth-openshift` pods, sometimes twice

The authentication operator copies `htpass-secret` into a projected volume
(`v4-0-config-user-idp-0-file-data`) and folds the resourceVersions it
watches into the pod-template annotation `operator.openshift.io/rvs-hash`.
That annotation changing is what triggers the `oauth-openshift` Deployment
rollout (`maxSurge:3, maxUnavailable:2` — so logins can briefly fail
mid-rollout, not fail outright).

**One rollout is not always enough to wait for.** Verified live: `oc get co
authentication` can report `Available=True Progressing=False Degraded=False`
while the Deployment is still mid-rollout — old pods `Terminating`, new ones
`Pending` — so a login attempt in that window can still 401 against a pod
serving the old secret. Worse, the operator can react to the secret change
with a short lag and start a *second*, corrective rollout just after the
first one converges: `oc rollout status` reported success for a rollout
built from a stale `rvs-hash`, and a fresh rollout carrying the real content
began roughly 15 seconds later. `manage-cluster-users.sh` waits on the
Deployment's rollout, re-checks whether its generation is still moving, and
only then polls `co/authentication` — never on `oc get co` in aggregate,
since `network` and `storage` are permanently `Progressing=True` on this
cluster (see `docs/runbook.md`, Known-inert) and an aggregate wait would
never terminate.

### Lockout: three doors, and OAuth can only close one

1. **The admin kubeconfig's client certificate** — `O=system:masters,
   CN=system:admin`, signed by `admin-kubeconfig-signer` (verified valid to
   2036-08-15), bound to `cluster-admin` via the bootstrap
   `ClusterRoleBinding`. It authenticates at the kube-apiserver by client
   certificate and **never touches OAuth at all** — no change to the OAuth
   CR, a missing or malformed secret, or a deleted identity provider can
   affect it. This is the real break-glass, and the reason htpasswd changes
   here are low-risk.
2. **`kubeadmin`** — implemented outside `spec.identityProviders` entirely
   (its own `operator.openshift.io/bootstrap-user-exists` annotation), so it
   survives a totally broken htpasswd IdP. Kept deliberately as a second
   door, not removed by this tooling.
3. **htpasswd** — the new one, and the only door any of this script's
   commands can affect.

The one genuine break this design can cause is a missing or malformed
`htpass-secret` with the OAuth CR still pointing at it. Doors 1 and 2 are
unaffected either way; recovery is `--sync` to refresh the local cache from
whatever the cluster currently has, then `--add` through door 1 (the admin
kubeconfig).

## Storage: EFS used as a plain NFS server, not through a CSI driver

The short version: **this cluster cannot hold a cloud credential**, so it
cannot run a CSI driver, so its storage has to come from something that speaks
a protocol rather than an AWS API.

`install-config` sets `credentialsMode: Manual` — an SSO session cannot supply
the long-lived keys the Cloud Credential Operator would otherwise mint — so
nothing issues credentials automatically. Both ways of supplying them by hand
are hard-denied, probed for real rather than assumed:

```
iam:CreateUser                    explicit deny, policy p-cf140vwn
iam:CreateOpenIDConnectProvider   explicit deny, policy p-77bk5ceo
```

That rules out both the static-key path and the OIDC/STS path, which are the
only two supported ways to give an AWS CSI driver an identity.

The instance profile is not a way out either, and this one fails for a reason
that has nothing to do with SCPs: the EBS CSI **controller** runs on the pod
network (`hostNetwork: false`), and OVN-Kubernetes does not forward pod traffic
to `169.254.169.254`. It can therefore never reach IMDS to borrow the node's
identity. Confirmed directly on this cluster — from a node, IMDS returns
`horizon-horizon-master`; from a pod, no response at all, with the hop limit
raised to 2 and no firewall rule on the node to explain it. This is why the
IMDS hop limit is pinned at **1** in `modules/control-plane`: raising it to 2
looks like it should open that path and measurably does not, so the larger
blast radius buys nothing.

**The same wall shows up in three other places**, and it is worth recognising it
once rather than debugging it three more times:

- `machine-api` cannot reconcile the masters' `Machine` objects — they exist,
  but sit at an empty `phase` with `failed to create aws client: aws credentials
  secret openshift-machine-api/aws-cloud-credentials ... not found`. That is the
  real reason `control-plane-machine-set` reports Degraded, not the "UPI has no
  Machine objects" explanation that sounds right.
- The image registry's native S3 backend is unusable for the same reason, which
  is why the registry is backed by a PVC on `efs-nfs` instead.
- `cloud-network-config-controller` never starts: its pod sits in
  `ContainerCreating` forever on `MountVolume.SetUp failed for volume
  "cloud-provider-secret" : secret "cloud-credentials" not found`. This keeps the
  `network` clusteroperator permanently `Progressing=True`, though it stays
  `Available=True` and `Degraded=False` — the controller only manages optional
  cloud networking features (egress IPs and similar), none of which this design
  uses. Benign, and not worth chasing.
- Any future operator that expects to call an AWS API from a pod will fail the
  same way. The question to ask first is always "what identity does this think
  it has?"

**EFS is the way through, and it was worth probing rather than assuming** — it
is the first capability tested in this account that turned out *not* to be
blocked:

```
elasticfilesystem:CreateFileSystem    ALLOWED
elasticfilesystem:CreateMountTarget   ALLOWED (ENI placed in the private subnet)
```

Because EFS speaks NFSv4.1, nothing inside the cluster ever calls an AWS API:
static PVs need no driver at all, and dynamic provisioning is done by
`nfs-subdir-external-provisioner`, which only ever performs NFS operations.
A mount target is simply an ENI holding an IP in the private subnet, which is
also why this works with `ec2:CreateVpcEndpoint` denied — there is no endpoint
involved.

`terraform/modules/efs` builds the filesystem, its own security group (NFS 2049
referenced by security group, never CIDR — the subnet is shared with other
teams), and one mount target per subnet.

### Two OpenShift-specific details in the provisioner manifest

`manifests/storage/nfs-provisioner.yaml` is not the upstream example manifest,
for two reasons that are easy to trip over:

1. **It mounts the export through a PVC, not a pod-level `nfs:` volume.**
   OpenShift's default `restricted-v2` SCC does not permit the `nfs` volume
   type, so a direct `nfs:` volume would require running the provisioner under
   a privileged SCC. Going via a PersistentVolume lets kubelet perform the
   mount and keeps the pod under the default SCC.
2. **The export root is `/openshift`, pre-created mode 1777** — not `/`, which
   EFS leaves as `root:root 755`. Pods here run as an arbitrary non-root UID,
   so a world-writable, sticky parent is what lets the provisioner create
   per-PVC subdirectories at all.

**Who creates `/openshift`, and why it can't be the cluster.** Something with
root has to touch EFS once to create that directory — no pod can do it, for the
same reason no CSI driver works: nothing in the cluster can hold the identity
or the privilege for a raw root-level NFS operation. Using `/` as the export
root instead doesn't dodge this: you'd still need one root-level `chmod 1777`
on it, and now the *entire* filesystem is world-writable rather than one
subtree. The one-time root operation is irreducible; only the blast radius is
a choice.

An EFS Access Point looked like it could avoid this from Terraform alone —
it can auto-create a root directory with a given owner/mode. It doesn't work
here: AWS's own docs are explicit that this only happens *at mount time*
through the access point, not at `CreateAccessPoint` time, and mounting
through an access point needs the EFS mount helper (`-o
tls,accesspoint=fsap-...`), which the in-tree `nfs:` volume type this design
relies on cannot do. So it would still need something to mount once, plus an
extra `elasticfilesystem:CreateAccessPoint` call that may itself be
SCP-denied in a client account — strictly worse.

**The bastion does it**, over SSM, via `day2/prepare-efs-root.sh`: it's
already the utility box for this deployment (DNS, HAProxy, ignition server,
SSM entry point), and it's the one thing that exists before any cluster node
does. `terraform/main.tf`'s `module "efs"` gives it a client security-group
rule for exactly this; `terraform/templates/bastion-userdata.sh.tpl` installs
`nfs-utils`, though that only reaches a bastion built after this change —
`prepare-efs-root.sh` installs the package itself over SSM too, so it works
on an existing bastion without a rebuild. This also leaves a standing way to
inspect what's on EFS, which matters because of `onDelete: retain` below —
deleted PVCs leave directories behind with no way to see or reap them
otherwise.

The StorageClass uses `onDelete: retain`, keeping data after a PVC is deleted
until an operator decides otherwise — the alternative silently discards
contents, and EFS storage is cheap.

**Trade-off accepted:** this is file storage (RWX, `allowVolumeExpansion:
false`), not block. That is fine for general workloads and wrong for a heavy
database — anything wanting block semantics or single-writer performance has no
answer in this account today.

### The image registry rides on the same storage

The cluster originally shipped with no image registry, because there was no
storage to put one on. Once `efs-nfs` existed, that reason expired and the
registry was enabled (19 Aug 2026), backed by a PVC rather than S3.

S3 is unavailable here for exactly the reason the CSI drivers are: the registry
runs as a pod, and pods cannot hold an AWS credential. This is worth stating
plainly because S3 *is* reachable from this VPC — the bastion pulls ignition
from it on every boot. The obstacle is identity, not connectivity, and that
distinction is easy to lose.

`ReadWriteMany` is what makes the registry's default two-replica
`RollingUpdate` shape work: both pods mount the same volume at once. On RWO
storage the registry has to run a single replica with `Recreate`.

**One caveat carried knowingly.** Red Hat's guidance cautions against
NFS-backed registry storage, on concurrent-write and file-locking grounds; that
guidance was written against RHEL's NFS server rather than AWS-managed EFS, so
this is not precisely the configuration they tested, but it is close enough that
the caveat should not be waved away. A full build → push → pull round-trip was
verified working on 19 Aug 2026. If push corruption or stuck mounts ever appear,
the fallback is one replica with `rolloutStrategy: Recreate`, which removes the
concurrent-write question entirely.

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
