#!/usr/bin/env bats

load helpers

run_merge() { run "$BATS_TEST_DIRNAME/../merge.sh"; }

# The pull request is behind its base and carries the label unless a test says otherwise; credentials are an ssh-key because rebase takes no merge method.
setup_rebase() {
  export THEN=rebase MERGE_METHOD= MERGE_TOKEN= SSH_KEY=key BEHIND_BY=2 HEAD_SHA=
  export WHEN=$'label: automerge\nbehind'
}

@test "rebase brings a pull request that is behind its base up to date and pushes with a lease on its head" {
  setup_rebase
  run_merge
  assert_success
  assert_output --partial "was behind main; rebased it"
  run cat "$MERGE_LOG"
  assert_output --partial "HEAD:refs/heads/topic --force-with-lease=refs/heads/topic:abc"
}

@test "rebase considers every open pull request, whatever commit triggered the run" {
  setup_rebase
  OPEN_PULLS=$'7\n8' run_merge
  assert_success
  assert_output --partial "#7 was behind main"
  assert_output --partial "#8 was behind main"
}

@test "rebase leaves a pull request that is not behind alone" {
  setup_rebase
  BEHIND_BY=0 run_merge
  assert_success
  assert_output --partial "#7 isn't behind main"
  run cat "$MERGE_LOG"
  refute_output --partial "push "
}

@test "rebase leaves a pull request that fails another condition alone" {
  setup_rebase
  PR_LABEL=other run_merge
  assert_output --partial "isn't labelled automerge"
  run cat "$MERGE_LOG"
  refute_output --partial "push "
}

@test "rebase leaves a fork alone" {
  setup_rebase
  PR_FORK=true run_merge
  assert_output --partial "comes from a fork"
  run cat "$MERGE_LOG"
  refute_output --partial "push "
}

@test "rebase leaves a branch with merge commits to linearise" {
  setup_rebase
  MERGE_COMMITS=m1 run_merge
  assert_success
  assert_output --partial "linearise it first"
  run cat "$MERGE_LOG"
  refute_output --partial "push "
}

@test "rebase pushes nothing when the rebase conflicts" {
  setup_rebase
  REBASE_FAILS=1 run_merge
  assert_success
  assert_output --partial "doesn't rebase cleanly"
  run cat "$MERGE_LOG"
  refute_output --partial "push "
}

@test "rebase says so when no pull request is open" {
  setup_rebase
  OPEN_PULLS= run_merge
  assert_success
  assert_output --partial "No open pull request."
}

@test "rebase works with a token as well as a deploy key" {
  setup_rebase
  MERGE_TOKEN=write SSH_KEY= run_merge
  assert_success
  run cat "$MERGE_LOG"
  assert_output --partial "auth http.extraheader="
}

@test "rebase needs a credential that starts workflows" {
  setup_rebase
  SSH_KEY= run_merge
  assert_failure
  assert_output --partial "then: rebase needs merge-token, app-id or ssh-key"
}

@test "rebase refuses two credentials and merge settings" {
  setup_rebase
  MERGE_TOKEN=write run_merge
  assert_failure
  assert_output --partial "one credential"
  setup_rebase
  MERGE_METHOD=rebase run_merge
  assert_failure
  assert_output --partial "merge-method is only used by then: merge"
  setup_rebase
  UPDATE_BEHIND=true run_merge
  assert_failure
  assert_output --partial "update-behind is only used by then: merge"
}
