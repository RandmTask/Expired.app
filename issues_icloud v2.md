# iCloud / CloudKit notes → moved

The CloudKit + SwiftData lessons that used to live here have been consolidated into the
cross-app playbook so every project shares one source of truth:

**→ [`../../_shared/cloudkit-swiftdata.md`](../../_shared/cloudkit-swiftdata.md)**

That playbook folds in everything from this file plus the SteadyState and HomeHub copies plus
the full suite of HomeHub Jun 2026 sync fixes (the 1 MB blob / partial-failure trap, CKAsset photos,
change-detection writes to stop last-writer-wins reverts, tombstone deletes, deterministic
migration ids, and the honest-status diagnostics harness).

Do not re-add lessons here. Add new CloudKit lessons to the shared playbook and reference
them from `IMPLEMENTATION_LOG.md`. (Prior content remains in git history.)
