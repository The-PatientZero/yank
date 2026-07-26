# CloudKit Backfill Runbook

Yank includes a one-time, UUID-preserving recovery command for local Mac records that are
missing from the user's private CloudKit database. Existing remote records are not updated or
deleted. The command is safe to retry: it checks record presence again and uploads only records
that are still missing.

Use a signed build whose CloudKit container is provisioned. Quit the normal Yank process first,
enable iCloud sync in Yank, confirm the local history is the intended source of truth, and keep a
copy of the command output with the release evidence.

## Dry run

```bash
"/Applications/Yank.app/Contents/MacOS/Yank" --cloudkit-backfill-dry-run
status=$?
echo "exit=$status"
```

A successful dry run exits `0` and prints one `YANK_CLOUD_BACKFILL_RESULT status=success` line.
`missingBefore` is the number that an apply would attempt to upload; `uploaded` remains zero.

## Apply and verify

```bash
"/Applications/Yank.app/Contents/MacOS/Yank" --cloudkit-backfill
status=$?
echo "exit=$status"
```

A successful apply exits `0` only after the post-upload presence check converges with
`remainingMissing=0`. Run the dry run again and retain both marker lines as evidence. A repeated
apply is idempotent and should report `missingBefore=0` and `uploaded=0`.

Any prerequisite, CloudKit, partial-save, or non-convergence failure exits nonzero and prints a
single `YANK_CLOUD_BACKFILL_FAILURE` or `status=failure` marker. Do not infer success from uploaded
counts when the exit status is nonzero. Preserve local history, resolve the reported prerequisite
or network/account condition, and retry; never delete local history or reset CloudKit checkpoints
to force convergence.
