# Layer-3 acceptance (macOS VM)

Runs the real loopback + pf + resolver path — the one thing the `bats` stub
harness can't cover. Needs a **fresh Apple-silicon macOS VM** (Virtualization.framework
only virtualizes macOS guests on Apple silicon). Not part of `bats`, not run in this project's CI.

## Steps
1. On an Apple-silicon Mac: `brew install cirruslabs/cli/tart`
2. `tart clone ghcr.io/cirruslabs/macos-sequoia-base:latest devip-accept`
3. `tart run devip-accept &` — log in, copy this repo in (or `git clone`)
4. Inside the VM: `brew install dnsmasq bats-core && bash test/acceptance/vm-provision.sh`
5. Expect `ACCEPTANCE PASSED`. Then discard: `tart delete devip-accept`.

"No residue" = deprovision returns the clone to its base state (re-clone to reset).
