#!/usr/bin/env bats

load helpers

LOST='[{"message":"The self-hosted runner lost communication with the server. Verify the machine is running and has a healthy network connection. Anything in your workflow that terminates the runner process, starves it for CPU/Memory, or blocks its network access can cause this error."}]'
# GitHub's text is cut off partway through its second sentence in a captured annotation, so only its prefix is relied on.
LOST_CUT='[{"message":"The self-hosted runner lost communication with the server. Verify the machine is running and has a healthy network connection. Anything in your workflow that terminates the runner process, starves it for CPU/Memory"}]'
TIMEOUT='[{"message":"The job has exceeded the maximum execution time of 15m0s"}]'
TEST_FAILURE='[{"message":"Process completed with exit code 1."}]'

# A failed workflow run: every job is described by its id and conclusion, and its annotations come from ANNOTATIONS_<id>.
setup_run() {
  export RUN_ID=99 RERUN_LOST_RUNNERS=2
  export RUN_JOBS='[{"id":1,"name":"build","conclusion":"failure"},{"id":2,"name":"lint","conclusion":"success"},{"id":3,"name":"test","conclusion":"cancelled"}]'
}

rerun() { run "$BATS_TEST_DIRNAME/../merge.sh"; }

reran() { grep -q '^rerun ' "$MERGE_LOG"; }

@test "a run whose failed jobs were all lost to the runner is re-run" {
  setup_run
  ANNOTATIONS_1=$LOST ANNOTATIONS_3=$LOST_CUT rerun
  assert_success
  reran
  run cat "$MERGE_LOG"
  assert_output "rerun repos/o/r/actions/runs/99/rerun-failed-jobs"
}

@test "a runner-loss annotation cut short still counts" {
  setup_run
  RUN_JOBS='[{"id":1,"name":"build","conclusion":"failure"}]' ANNOTATIONS_1=$LOST_CUT rerun
  assert_success
  reran
}

@test "a job that failed with a test error stops the re-run" {
  setup_run
  ANNOTATIONS_1=$LOST ANNOTATIONS_3=$TEST_FAILURE rerun
  assert_success
  ! reran
  assert_output --partial "- test: left alone, it did not fail for want of its runner"
  assert_output --partial "- build: left alone, another failed job was not lost to its runner"
}

@test "a job cancelled by its own timeout stops the re-run" {
  setup_run
  ANNOTATIONS_1=$LOST ANNOTATIONS_3=$TIMEOUT rerun
  assert_success
  ! reran
  assert_output --partial "test: left alone, it exceeded the maximum execution time"
}

@test "a failed job with no annotation is left alone" {
  setup_run
  ANNOTATIONS_1=$LOST rerun
  assert_success
  ! reran
  assert_output --partial "- test: left alone, it did not fail for want of its runner"
}

@test "a run with no failed job is not re-run" {
  setup_run
  RUN_JOBS='[{"id":2,"name":"lint","conclusion":"success"},{"id":4,"name":"docs","conclusion":"skipped"}]' rerun
  assert_success
  ! reran
  assert_output --partial "nothing to re-run"
}

@test "each job is named in the step summary with its reason" {
  setup_run
  ANNOTATIONS_1=$LOST ANNOTATIONS_3=$LOST_CUT rerun
  assert_success
  run cat "$GITHUB_STEP_SUMMARY"
  assert_line "- build: re-run, the runner was lost"
  assert_line "- test: re-run, the runner was lost"
  refute_output --partial "lint"
}

@test "a re-run stops once the run's attempt number passes the limit" {
  setup_run
  RUN_JSON='{"conclusion":"failure","run_attempt":3}' ANNOTATIONS_1=$LOST ANNOTATIONS_3=$LOST rerun
  assert_success
  ! reran
  assert_output --partial "attempt 3 is past the limit of 2"
}

@test "the last attempt within the limit is still re-run" {
  setup_run
  RUN_JSON='{"conclusion":"failure","run_attempt":2}' ANNOTATIONS_1=$LOST ANNOTATIONS_3=$LOST rerun
  assert_success
  reran
}

@test "a failed run never reaches the merge" {
  setup_run
  ANNOTATIONS_1=$LOST ANNOTATIONS_3=$LOST rerun
  assert_success
  run grep -c '^merge ' "$MERGE_LOG"
  assert_output 0
}

@test "a successful run carries on to the merge as before" {
  setup_run
  RUN_JSON='{"conclusion":"success","run_attempt":1}' rerun
  assert_success
  ! reran
  assert_output --partial "Merged #7."
}

@test "a limit of 0 does nothing and leaves the merge as it was" {
  setup_run
  RERUN_LOST_RUNNERS=0 ANNOTATIONS_1=$LOST ANNOTATIONS_3=$LOST rerun
  assert_success
  ! reran
  assert_output --partial "Merged #7."
}

@test "an unset limit does nothing, whatever the run" {
  setup_run
  unset RERUN_LOST_RUNNERS
  ANNOTATIONS_1=$LOST ANNOTATIONS_3=$LOST rerun
  assert_success
  ! reran
  assert_output --partial "Merged #7."
}

@test "a limit that is not a whole number is rejected" {
  setup_run
  RERUN_LOST_RUNNERS=two rerun
  assert_failure
  assert_output --partial "rerun-lost-runners must be a whole number"
}

@test "a limit without a workflow run to look at is rejected" {
  setup_run
  RUN_ID= rerun
  assert_failure
  assert_output --partial "rerun-lost-runners needs a workflow_run event"
}

@test "a limit is rejected with an effect other than merge" {
  setup_run
  THEN=ready MERGE_METHOD= WHEN="label: automerge" rerun
  assert_failure
  assert_output --partial "rerun-lost-runners is only used by then: merge"
}

@test "a runner-loss annotation counts whatever the job's conclusion" {
  setup_run
  for conclusion in cancelled timed_out action_required; do
    : >"$MERGE_LOG"
    RUN_JOBS="[{\"id\":1,\"name\":\"build\",\"conclusion\":\"$conclusion\"}]" ANNOTATIONS_1=$LOST rerun
    assert_success
    reran
  done
}

@test "a timed out job with no annotation is a timeout and stops the re-run" {
  setup_run
  RUN_JOBS='[{"id":1,"name":"build","conclusion":"failure"},{"id":3,"name":"test","conclusion":"timed_out"}]' ANNOTATIONS_1=$LOST rerun
  assert_success
  ! reran
  assert_output --partial "- test: left alone, it exceeded the maximum execution time"
}

@test "a job with no conclusion is still running and is ignored" {
  setup_run
  RUN_JOBS='[{"id":1,"name":"build","conclusion":"failure"},{"id":3,"name":"test","conclusion":null}]' ANNOTATIONS_1=$LOST ANNOTATIONS_3=$TEST_FAILURE rerun
  assert_success
  reran
  refute_output --partial "- test"
}

@test "a neutral job is ignored like a skipped one" {
  setup_run
  RUN_JOBS='[{"id":1,"name":"build","conclusion":"failure"},{"id":3,"name":"test","conclusion":"neutral"}]' ANNOTATIONS_1=$LOST ANNOTATIONS_3=$TEST_FAILURE rerun
  assert_success
  reran
}

@test "one genuine failure beside a runner loss stops the re-run" {
  setup_run
  RUN_JOBS='[{"id":1,"name":"build","conclusion":"cancelled"},{"id":3,"name":"test","conclusion":"failure"}]' ANNOTATIONS_1=$LOST ANNOTATIONS_3=$TEST_FAILURE rerun
  assert_success
  ! reran
  assert_output --partial "- build: left alone, another failed job was not lost to its runner"
}
