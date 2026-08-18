# Running and Reading the Preflight Suite

## What it's for

Before standing up real cluster infrastructure in a new client AWS account,
`scripts/preflight/run-all.sh` proves two things against that specific
account:

1. **The capabilities UPI actually needs work** — security groups, ENIs, IAM
   roles/instance profiles, S3 read/write, launching an instance and
   reaching it via SSM, and outbound internet access from the private
   subnet (the bastion's ignition/haproxy-config S3 pull depends on this —
   see `docs/architecture.md`). The launch/SSM canaries deliberately use an
   AWS-owned base AMI, not RHCOS — AMI *ownership* restrictions are a
   separate, already-solved concern (`scripts/ami-build/build-custom-ami.sh`),
   not a generic launch-capability question.
2. **The capabilities we're deliberately avoiding are still blocked (or
   aren't)** — `ec2:CreateVpc`, `ec2:AllocateAddress`,
   `elasticloadbalancing:CreateLoadBalancer`. See `docs/scp-blockers.md` —
   note that two other real findings (AMI-ownership restrictions, the
   vmimport block) came from manual end-to-end testing, not this automated
   probe, and aren't yet covered by a fast canary here.

Both checks create real, minimal resources and clean them up afterward —
this is not a static/offline check. It needs real AWS credentials for the
target account.

## Running it

```
cp accounts/example.tfvars.sample accounts/<account-alias>.tfvars
# fill in aws_region / existing_vpc_id / existing_private_subnet_id

cd preflight && terraform init
../scripts/preflight/run-all.sh -a <account-alias>
```

No AMI needs to be resolved beforehand — the launch/SSM/egress canaries use
an AWS-owned base AMI looked up on demand (see `preflight/fixtures/ec2-canary`).
Building the real RHCOS AMI this account will actually use for cluster
nodes is a separate step: `scripts/ami-build/build-custom-ami.sh`.

## Reading the result

Exit code 0 means: every "should succeed" canary passed, every "should
fail" SCP probe was correctly denied, and nothing was left inconclusive.
Anything else is a real finding, not noise — see
`preflight/reports/<account-alias>-<timestamp>-summary.json` for the
machine-readable version, or the console table for a quick read.

- A canary **failing** to apply means this account can't do something UPI
  needs — the deployment will fail the same way, just later and with more
  at stake. Fix the underlying IAM/SCP gap before proceeding.
- An SCP probe reporting **UNEXPECTED_SUCCESS** means an operation we
  assumed was blocked actually isn't on this account. Worth a second look —
  this account's restrictions may differ from the one this design was
  originally built against, and some of the bastion/HAProxy/existing-VPC
  workarounds might not be necessary here.
- An SCP probe reporting **INCONCLUSIVE** means the probe failed for a
  reason other than an authorization error (e.g. a parameter validation
  issue). Never treated as proof of anything — investigate directly.

## Cleanup guarantees

`run-all.sh` runs `scripts/preflight/cleanup-orphans.sh` unconditionally on
exit (success, failure, or interrupt), sweeping anything still tagged
`Purpose=ocp-preflight` or `Purpose=ocp-preflight-scp-probe` via the AWS
Resource Groups Tagging API. This is a backstop for the case where
`terraform test`'s own destroy, or an SCP probe's inline cleanup, was itself
interrupted — not the primary cleanup path.

## Adding a new canary

1. If it exercises a real production module, add a fixture under
   `preflight/fixtures/` only if there's no reasonable way to test the
   module directly in a `run` block (see `03_s3_bucket.tftest.hcl`'s
   `fixtures/s3-roundtrip` for an example of wrapping a production module to
   add a canary-specific action).
2. Add a new `preflight/tests/NN_description.tftest.hcl` file. Copy the
   boilerplate pattern from an existing file — **every run block that uses
   an explicit `module { source = ... }` needs its own `provider "aws" {}`
   block in the file plus `providers = { aws = aws }` on the run block**,
   or it'll fail with a confusing "Invalid provider configuration" error
   that looks like a credentials problem. See `docs/architecture.md`'s
   "terraform test gotcha" section for why.
3. `run-all.sh` picks up every file under `preflight/tests/` automatically —
   no registration needed elsewhere.
