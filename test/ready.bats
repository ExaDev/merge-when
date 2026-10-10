#!/usr/bin/env bats

load helpers

# then: ready takes no merge method, so each test starts from one that would otherwise be valid for it.
run_ready() { THEN=ready MERGE_METHOD= WHEN=$'label: automerge\ncheck: Required checks' run "$BATS_TEST_DIRNAME/../merge.sh"; }

touched() { [ -s "$MERGE_LOG" ]; }

@test "ready marks a draft ready for review with the merge token" {
  PR_DRAFT=true run_ready
  assert_success
  assert_output --partial "Marked #7 ready for review."
  run cat "$MERGE_LOG"
  assert_output "ready pr ready 7 --repo o/r with write"
}

@test "ready leaves a pull request that is already ready alone" {
  PR_DRAFT=false run_ready
  assert_success
  assert_output --partial "already ready for review"
  ! touched
}

@test "ready still needs every condition to hold" {
  PR_DRAFT=true CHECK_PASSED=0 run_ready
  assert_output --partial "\"Required checks\" hasn't passed"
  ! touched
}

@test "ready is rejected with the not-draft condition" {
  PR_DRAFT=true THEN=ready MERGE_METHOD= WHEN=$'label: automerge\nnot-draft' run "$BATS_TEST_DIRNAME/../merge.sh"
  assert_failure
  assert_output --partial "can't be combined with the not-draft condition"
  ! touched
}

@test "ready is rejected with a merge method" {
  PR_DRAFT=true THEN=ready MERGE_METHOD=rebase WHEN="label: automerge" run "$BATS_TEST_DIRNAME/../merge.sh"
  assert_failure
  assert_output --partial "merge-method is only used by then: merge"
  ! touched
}

@test "ready is rejected with an ssh key" {
  PR_DRAFT=true SSH_KEY=key run_ready
  assert_failure
  assert_output --partial "ssh-key is only used by then: merge"
  ! touched
}

@test "ready is rejected with update-behind" {
  PR_DRAFT=true UPDATE_BEHIND=true run_ready
  assert_failure
  assert_output --partial "update-behind is only used by then: merge"
  ! touched
}

@test "ready is rejected without a merge token, since GITHUB_TOKEN starts no workflows" {
  PR_DRAFT=true MERGE_TOKEN= run_ready
  assert_failure
  assert_output --partial "then: ready needs merge-token or app-id"
  ! touched
}

@test "an unknown effect is rejected" {
  THEN=close run "$BATS_TEST_DIRNAME/../merge.sh"
  assert_failure
  assert_output --partial "then must be merge or ready"
  ! touched
}
