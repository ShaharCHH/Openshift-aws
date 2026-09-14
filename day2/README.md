# day2/

Run-once scripts that finish a cluster off after `openshift-install
wait-for install-complete` succeeds (`docs/runbook.md`'s Phase 7 onward).
Everything here is idempotent and safe to re-run, but none of it is meant to
run on a schedule the way `scripts/tunnel.sh` or `scripts/hibernate.sh` are
-- for that recurring, "run this whenever" surface, see `scripts/` instead.

Run in this order:

```bash
./day2/apply-storage.sh -a <alias>      # prepares the EFS export root, then
                                          # applies the NFS provisioner + efs-nfs
./day2/verify-storage.sh -a <alias>     # proves a PVC actually binds
./day2/setup-registry.sh -a <alias>     # registry PVC + the S3-stanza patch + external route
./day2/verify-registry.sh -a <alias>    # build -> push -> pull round-trip + route check
./day2/post-install-cleanup.sh -a <alias>   # storage operator, StorageClasses,
                                              # known-inert operator check
```

`apply-storage.sh` calls `prepare-efs-root.sh` itself, so you don't need to
run that one separately unless you want to check the export root in
isolation.

All of these need `oc` on PATH and a reachable API -- either
`./scripts/tunnel.sh -a <alias>` running, or run them from the bastion
itself, which reaches the API directly over the VPC (see `docs/runbook.md`'s
note on why that's preferable for anything heavier than a quick check).

Every script here reads `.ignition/<alias>/auth/kubeconfig` directly rather
than depending on `~/.kube/config` having been merged
(`scripts/update-kubeconfig.sh` is unrelated to any of this).
