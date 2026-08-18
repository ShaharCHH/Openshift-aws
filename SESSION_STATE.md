# Session state — 18 Aug 2026

Point-in-time handoff, not a design doc. `docs/architecture.md`, `docs/runbook.md`
and `docs/scp-blockers.md` are the durable references; if this file disagrees with
them, they win. Delete it once its next-steps are done.

**Cluster is HIBERNATED** (`./scripts/hibernate.sh -a horizon`). Wake with
`./scripts/wake.sh -a horizon`.

| | |
|---|---|
| Cluster | `horizon.ocp.internal`, account `342831714456`, `il-central-1` |
| infraID | `horizon-sb9vp` (regenerated today — CA and infraID changed) |
| RHCOS AMI | `ami-093702d1ac869e178` |
| Bastion AMI | `ami-0487e9d84db7c95ff` (now pinned) |
| EFS | `fs-0c1fcee2e853c5026`, mount target `10.3.65.227` |
| Nodes | 3 masters, compact topology, schedulable |

---

## 1. What we accomplished

First cluster in this project ever to reach `bootstrap-complete` — in **4m20s**,
where every previous attempt timed out at 45 minutes. Ended with 3/3 nodes
`Ready`, console reachable, and working dynamic RWX storage. 10 commits.

Nine blockers found and fixed. Ordered by how much they cost:

1. **Nodes lost their IP on every reboot** — killed the previous cluster
   outright. The AMI's `ip=dhcp nameserver=` kernel args configure the
   initramfs only; RHEL 9 then leaves the real root with no persistent
   NetworkManager profile. First boot always looked fine, so five earlier
   sessions never saw it — they all died of something else before a reboot.
2. **Geneve UDP 6081 blocked** between nodes — OVN could not carry cross-node
   pod traffic. Surfaced three layers away as flapping ingress pods.
3. **No cloud credential is possible in this account** — see decisions below.
4. Ignition served before the files existed (404 is fatal to Ignition;
   connection-refused is not) — four nodes died in emergency mode.
5. `kubernetes` ClusterIP → bootstrap:6443 not permitted.
6. etcd 2379-2380 between bootstrap and masters not permitted.
7. HAProxy → master 80/443 not permitted.
8. Five missing EC2 IAM read permissions, found one crash-loop at a time.
9. Ingress defaulted to an SCP-blocked ELB, wedging two objects in `Terminating`.

### Files modified

```
terraform/modules/security-groups/main.tf   ClusterIP, etcd, ingress, pod-network rules
terraform/modules/efs/                      NEW — filesystem, mount target, SG
terraform/modules/control-plane/main.tf     NM keyfile in wrapper ignition; hop limit pinned 1
terraform/modules/bootstrap/main.tf         NM keyfile in wrapper ignition
terraform/modules/bastion/main.tf           oc install, ami_id passthrough
terraform/modules/iam/main.tf               EC2 read permissions for the cloud provider
terraform/templates/node-network.nmconnection.tpl   NEW — the reboot fix
terraform/templates/bastion-userdata.sh.tpl sync-before-serve, oc, /etc/hosts
terraform/{main,variables,outputs}.tf       EFS module, bastion_ami_id
manifests/storage/nfs-provisioner.yaml      NEW — dynamic storage
scripts/ami-build/verify-ami-reboot.sh      NEW — the gate that catches #1
scripts/ignition/generate-ignition.sh       HostNetwork IngressController manifest
docs/{architecture,runbook}.md              two-layer networking, reboot gate, troubleshooting
accounts/horizon.tfvars                     bastion_ami_id
```

---

## 2. Decisions settled

**Storage is EFS used as plain NFS — no CSI driver.** Three probes closed every
other door: `iam:CreateUser` denied (`p-cf140vwn`), `iam:CreateOpenIDConnectProvider`
denied (`p-77bk5ceo`), and OVN does not forward pod traffic to `169.254.169.254`
so the EBS CSI controller can never borrow the node's instance profile. EFS was
the first capability probed in this account that was **not** blocked. Dynamic
provisioning comes from `nfs-subdir-external-provisioner`, which only speaks NFS.
Trade-off accepted: file storage, not block — fine for general workloads, wrong
for a heavy database.

**Ingress is `HostNetwork`, pinned at install time.** Written as a manifest by
`generate-ignition.sh` between `create manifests` and `create ignition-configs`,
because `endpointPublishingStrategy` is immutable afterwards. The AWS default
(`LoadBalancerService`) tries to build an SCP-blocked ELB and deadlocks on a
finalizer that can never complete.

**Node networking is configured twice, deliberately.** Kernel args own the
initramfs (Ignition needs DNS before a root filesystem exists); the
NetworkManager keyfile owns the real root. Neither alone is sufficient. IMDS hop
limit is pinned at **1** — raising it to 2 looks like it should let pods reach
IMDS and does not, because OVN blocks that path regardless.

**Bastion AMI is pinned.** `most_recent = true` let Amazon's release schedule
replace the bastion mid-apply, which caused blocker #4.

**Security-group rules are referenced by group, never CIDR** — the subnet is
shared with other teams.

**No image registry**, by choice.

---

## 3. Next steps

1. **Wake and watch carefully.** `./scripts/wake.sh -a horizon`. This cluster has
   never survived a stop/start; the reboot fix is verified by
   `verify-ami-reboot.sh` but has not faced a real hibernate cycle. If nodes come
   back `NotReady`, check the console banner for `ens5:` with no address — that is
   blocker #1 returning, and the NM keyfile did not take.
2. **Two default StorageClasses.** `efs-nfs` and `gp3-csi` are both marked
   default, which is undefined behaviour. Remove the annotation from `gp3-csi`.
3. **`oc patch storage cluster --type=merge -p '{"spec":{"managementState":"Removed"}}'`**
   — the `storage` operator is Degraded solely because of the dead EBS CSI driver.
4. **Same for `image-registry`** (`managementState: Removed`), so CVO stops
   waiting on it.
5. **Confirm `control-plane-machine-set`** is inertly Degraded — expected on UPI
   where masters have no `Machine` objects — rather than assuming it.
6. **Update the onboarding docx** with today's findings: the two new SCP denials
   and their policy IDs, the IMDS-from-pods block, and EFS as the one thing that
   works. Generator is gone from scratch; rebuild from
   `~/Downloads/aws onboarding - v2 with field findings.docx`.
7. **Optional:** add preflight canaries for node-to-node reachability (Geneve,
   etcd, ClusterIP). Four bring-up cycles were spent finding SG gaps one at a time.

### Known-inert, do not chase

`control-plane-machine-set` Degraded is normal on UPI. `wait-for install-complete`
will keep failing while any operator is unavailable — items 3 and 4 are what
clear it.
