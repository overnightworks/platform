# Runbook: `check:pod-logs` fails

Symptom: `mise run check:pod-logs` exits 1 and names a file past the 30-day bound, a `.gz` or `.tmp`, a file with no
creation time, a clean that has not run within 25 hours or failed, or a listing that failed.
Impact: a pod log line may outlive the 30 days the apps' privacy texts promise.

## Check

1. The operator: `mise run check:pod-logs`. It passes with one line: the files under `/var/log/pods` and the oldest,
   when the clean last ran and when it runs next.

## Fix

1. The operator: `sudo systemctl start pod-logs-clean.service`. It runs the clean, then the check.
2. The operator: `mise run check:pod-logs`. A failed or never-run clean keeps failing it until step 1 has run.

Rollback: none. The clean deletes only what the bound allows, and a deleted log stays deleted.

## Escalate

The check still fails after step 1, names a file with no creation time, or cannot list `/var/log/pods`: the operator
gives its lines, which hold only file names and times, to the head.
