# Session state — 19 Aug 2026

Point-in-time handoff, not a design doc. `docs/architecture.md`, `docs/runbook.md`
and `docs/scp-blockers.md` are the durable references; if this file disagrees with
them, they win. Delete it once its next-steps are done.

> **The cluster is RUNNING, not hibernated.** It was woken this session and left
> up. Hibernate it when you are done: `./scripts/hibernate.sh -a horizon`.

| | |
|---|---|
| Cluster | `horizon.ocp.internal`, account `342831714456`, `il-central-1` |
| infraID | `horizon-sb9vp` |
| RHCOS AMI | `ami-093702d1ac869e178` |
| Bastion AMI | `ami-0487e9d84db7c95ff` (pinned) |
| EFS | `fs-0c1fcee2e853c5026` |
| Nodes | 3 masters, compact topology, schedulable, all `Ready` |

---

## 1. What happened today

**The hibernate/wake cycle was survived for the first time.** That was the open
risk in yesterday's handoff — the cluster had never been stopped and started
again. All three masters came back with their addresses intact, so the
NetworkManager keyfile fix holds beyond the MCO reboot it was written for. The
first reachability probe after `wake.sh` returned all-closed and looked like the
old bug returning; it was just early boot. Give it the 10 minutes the runbook
asks for.

**The internal image registry now exists**, reversing the earlier "no registry,
by choice" decision — that choice existed only because there was no storage, and
`efs-nfs` removed the reason. PVC-backed, 2 replicas on RWX, full build → push →
pull round-trip verified, blobs confirmed on EFS.

Also done: dynamic RWX storage re-verified after the reboot; the double-default
StorageClass fixed (`gp3-csi` annotation dropped).

## 2. Three corrections to yesterday's handoff

These mattered enough to fix in the durable docs:

1. **`control-plane-machine-set` is not Degraded because "UPI masters have no
   `Machine` objects."** They do have them. The machine controller cannot
   reconcile them: `aws credentials secret openshift-machine-api/aws-cloud-credentials
   ... not found`. Same credential wall as everything else.
2. **`oc patch storage cluster ... managementState: Removed` does not work.**
   The operator rejects it — `Removed is not supported for storage operator` —
   and adds a second degraded condition on top of the one you were clearing.
   **This is currently set on the cluster and should be put back to `Managed`.**
3. **The durable docs had never received the storage or ingress decisions.**
   Deleting this file, as its predecessor instructed, would have destroyed the
   reasoning behind the whole storage design. Both are now in
   `docs/architecture.md`, along with the two new IAM denials and the
   IMDS-from-pods dead end in `docs/scp-blockers.md`.

A fourth manifestation of the credential wall turned up while checking:
`cloud-network-config-controller` is stuck in `ContainerCreating` on `secret
"cloud-credentials" not found`, which is why `network` sits permanently
`Progressing`. Benign — documented as known-inert.

## 3. Next steps

1. **Revert the storage operator** — see correction 2 above:
   ```
   oc patch storage cluster --type=merge -p '{"spec":{"managementState":"Managed"}}'
   ```
   Then try `oc patch clustercsidriver ebs.csi.aws.com --type=merge -p
   '{"spec":{"managementState":"Removed"}}'`, which is the supported lever and is
   **untested**. If it is also refused, `storage` stays Degraded on this
   platform — record that and stop patching at it.
2. **Preflight canaries (was item 7, still open).** Planned in detail but not
   started: node-to-node reachability across all four security groups, plus
   `iam:CreateUser` / `iam:CreateOpenIDConnectProvider` deny-probes and an EFS
   allow-probe for `scp-probes.sh`. The worker rows matter most — this topology
   runs `compute.replicas: 0`, so no bring-up here has ever put a packet through
   a worker rule.
3. **Onboarding docx (was item 6).** Deferred deliberately — you want to rethink
   it rather than regenerate v2 plus deltas. Findings are safe in
   `docs/scp-blockers.md` meanwhile.

### Known-inert, do not chase

`control-plane-machine-set` Degraded, `storage` Degraded, and `network`
Progressing all trace to the same missing cloud credential. See
`docs/runbook.md`'s "Known-inert" list.
