# Repository instructions

## Before every commit

Stage the intended changes, then run:

```bash
./scripts/check-before-commit.sh
```

Do not create a commit unless this script passes. Fix any failures and run the
entire script again. If a required check cannot be run, stop and report the
reason instead of bypassing or weakening the check.

After it passes, inspect `git status --short` and `git diff --cached` to confirm
that the commit contains only the intended changes.
