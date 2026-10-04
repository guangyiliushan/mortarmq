## Summary

<!-- What changed, why now, and the user-visible or operational behavior? -->

## Scope

- [ ] This PR contains one concern.
- [ ] Every commit is a valid Conventional Commit and carries reviewable AI attribution.
- [ ] The diff is reviewable in one sitting; unrelated changes are split out.

## Quality gates

- [ ] `moon check --deny-warn --target all` passes.
- [ ] `moon fmt` followed by `git diff --exit-code` passes.
- [ ] Public-interface and formatting diffs are committed.
- [ ] Required tests pass for the affected targets.

## Behavior and documentation

- [ ] Behavior is unchanged, or the public docs in both trees changed in this PR.
- [ ] Plan or task identifiers are not present in source or workflow text.

## Compliance

- [ ] First contribution: I read [ICLA.md](./ICLA.md) and confirm the CLA.
      Skip this box only if this account already has a merged CLA-covered PR.
- [ ] No secrets, generated artifacts, vendored code, or machine-specific paths are included.
