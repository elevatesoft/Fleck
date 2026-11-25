# Branch-only focused Swift rehearsal

This overlay is solely for a disposable reviewed branch off
`c48749503e2ee57c0a91e577a98fe219e3f5b02f`. Never merge the overlay, make its
check required, or mistake it for PR or queue acceptance. Existing production
jobs, action inputs, check names and dependencies are unchanged. The inventory
test on this branch explicitly accounts for the single additional independent job.

No cache is restored. The job matches the cold and warm smoke toolchain exactly:
Xcode 26.6 (17F113), Swift 6.3.3 (swiftlang-6.3.3.1.3, clang-2100.1.1.101), SDK
26.5 under the explicitly selected Xcode installation. It stops rather than
downloading an SDK or changing global `xcode-select`.

- **Focus:** a cold positive fixture first, then a distinct synthetic commit
  containing one reachable assertion failure on the version-2 argument. The
  pinned selector must pick the Agent Protocol target for both. Compile each
  exactly once using a hash-pinned shadow-only AppKit wrapper with the SwiftBuild synthetic test product (`--product`, not the absent PIF module target); each
  uses its own freshly checked out source and build scratch. Read canonical
  discovered IDs plus per-case markers for exact argument values. A missing
  target, unsupported SwiftBuild option, no `.xctest`, wrong IDs or log
  format, unrelated test/app/bridge output, or infra failure makes the rehearsal inconclusive or failed. Do not
  silently fall back to building the full bundle.
- **Parity:** not enabled in this native branch. `prepare --phase parity`
  stages exact same positive/reachable identities plus a separate omitted
  negative control, without running Swift. A later reviewed native lane must
  compare focused and full-ordinary native evidence on identical source
  commits/trees and toolchain, and detect the deliberate focused-pass/full-fail
  regression. Stable synthetic commit dates make the two existing specimens'
  IDs reproducible. If exact same-SHA/toolchain evidence from this trusted
  rehearsal is retained and independently verified, a later experiment may
  reuse those observations rather than recompiling positive/reachable focused
  solely to repeat evidence; never reuse compiled outputs, and never reuse a
  rehearsal or PR result in a protected queue. Absent comparable receipts,
  rebuild those specimens in the separately authorized parity experiment.

Both outcomes are diagnostic; the focus verifier explicitly says parity
and branch protection were not validated. The actual dispatch (if separately
authorized) is on the exact reviewed branch and owner, using the existing
`ci.yml` and legacy `namespace_qualification_only=true`: ordinary CI and
all required lanes skip, while the independent metadata qualification job can
still run. Allow only the two diagnostic jobs expected to execute.

Record workflow queued/created time and job `started_at` separately. The
first hosted step prints UTC, the positive result prints exact completion UTC
and harness-to-completion seconds, and each specimen reports selector-through-
execution duration. Use API job start to positive verified UTC for the
cold end-to-end time, including runner setup, checkout and toolchain checks.
Queue wait is not hidden or attributed to compiler time. Thirty minutes is
a total stop cap for this two-specimen rehearsal, not a cold timing estimate.
No hosted result exists until the exact pinned run executes.
