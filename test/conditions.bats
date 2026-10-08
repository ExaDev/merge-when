#!/usr/bin/env bats

load helpers

run_merge() { run "$BATS_TEST_DIRNAME/../merge.sh"; }

merged() { [ -s "$MERGE_LOG" ]; }

@test "merges a pull request that meets every condition" {
  run_merge
  assert_success
  assert_output --partial "Merged #7."
  merged
}

@test "no open pull request for the commit" {
  OPEN_PULLS= run_merge
  assert_output --partial "No open pull request"
  ! merged
}

@test "a head that has moved on is left to its own run" {
  PR_HEAD=def run_merge
  assert_output --partial "moved on"
  ! merged
}

@test "label: the label must be present" {
  PR_LABEL=other run_merge
  assert_output --partial "isn't labelled automerge"
  ! merged
}

@test "check: the named check must have succeeded" {
  CHECK_RUNS='[{"name":"Required checks","conclusion":"failure"}]' run_merge
  assert_output --partial "\"Required checks\" hasn't passed"
  ! merged
}

@test "not-draft: a draft is left alone" {
  PR_DRAFT=true run_merge
  assert_output --partial "is a draft"
  ! merged
}

@test "threads-resolved: an unresolved thread blocks the merge" {
  UNRESOLVED=1 run_merge
  assert_output --partial "unresolved review thread"
  ! merged
}

@test "threads-resolved: more threads than one page count as unresolved" {
  UNRESOLVED=100 run_merge
  ! merged
}

@test "approvals: enough approvals merge" {
  WHEN=$'approvals: 2' PR_REVIEWS='[{"state":"APPROVED"},{"state":"APPROVED"}]' run_merge
  merged
}

@test "approvals: too few approvals do not" {
  WHEN=$'approvals: 2' PR_REVIEWS='[{"state":"APPROVED"}]' run_merge
  assert_output --partial "not the 2 approval(s) needed"
  ! merged
}

@test "approvals: an outstanding request for changes blocks even with enough approvals" {
  WHEN=$'approvals: 1' PR_REVIEWS='[{"state":"APPROVED"},{"state":"CHANGES_REQUESTED"}]' run_merge
  ! merged
}

@test "author: a listed author merges" {
  WHEN=$'author: dependabot[bot], renovate[bot]' PR_AUTHOR='renovate[bot]' run_merge
  merged
}

@test "author: anyone else does not" {
  WHEN=$'author: dependabot[bot]' run_merge
  assert_output --partial "isn't by dependabot[bot]"
  ! merged
}

@test "base: the target branch must match" {
  WHEN=$'base: release' run_merge
  assert_output --partial "doesn't target release"
  ! merged
}

@test "blank lines and comments in when are ignored" {
  WHEN=$'# opt in\n\nlabel: automerge\n' run_merge
  merged
}

@test "an unknown condition fails the run before anything is merged" {
  WHEN=$'label: automerge\nlabels: automerge' run_merge
  assert_failure
  assert_output --partial "Unknown condition"
  ! merged
}

@test "an empty when fails the run" {
  WHEN=$'# nothing\n' run_merge
  assert_failure
  assert_output --partial "no conditions"
}
