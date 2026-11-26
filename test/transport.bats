#!/usr/bin/env bats

load helpers

run_merge() { run "$BATS_TEST_DIRNAME/../merge.sh"; }

setup_fast_forward() { export MERGE_METHOD=fast-forward MERGE_TOKEN= SSH_KEY=key; }

dropped="Connection closed by 192.0.2.1 port 22"
denied="git@github.com: Permission denied (publickey)."

attempts() { grep -c "^attempt $1\$" "$MERGE_LOG"; }

@test "a push that keeps losing its connection fails the run with git's error" {
  setup_fast_forward
  PUSH_ERROR="$dropped" run_merge
  assert_failure
  assert_output --partial "$dropped"
  assert_output --partial "#7 could not be pushed to main"
  refute_output --partial "needs updating"
  refute_output --partial "Merged #7"
  assert_equal "$(attempts push)" 3
}

@test "update-behind does not rebase a pull request whose push failed while it contains its base" {
  setup_fast_forward
  PUSH_ERROR="$dropped" UPDATE_BEHIND=true run_merge
  assert_failure
  assert_output --partial "$dropped"
  refute_output --partial "rebased it"
  run cat "$MERGE_LOG"
  refute_output --partial "push "
  assert_equal "$(attempts push)" 3
}

@test "a push that loses its connection once is tried again and merges" {
  setup_fast_forward
  PUSH_ERROR="$dropped" PUSH_ERROR_TIMES=1 run_merge
  assert_success
  assert_output --partial "Merged #7."
  assert_equal "$(attempts push)" 2
}

@test "a push refused for a reason that is not the transport fails the run without another attempt" {
  setup_fast_forward
  PUSH_ERROR="$denied" PUSH_ERROR_TIMES=1 UPDATE_BEHIND=true run_merge
  assert_failure
  assert_output --partial "$denied"
  assert_equal "$(attempts push)" 1
}

@test "a failed push whose head turns out to be on the base is not rebased" {
  setup_fast_forward
  PUSH_ERROR="$dropped" HEAD_ON_BASE=1 UPDATE_BEHIND=true run_merge
  assert_success
  assert_output --partial "#7's head is already on main"
  refute_output --partial "rebased it"
}

@test "a failed push fails the run when git cannot say whether the pull request is behind" {
  setup_fast_forward
  PUSH_ERROR="$denied" ANCESTRY_FAILS=1 UPDATE_BEHIND=true run_merge
  assert_failure
  assert_output --partial "Not a valid commit name"
  refute_output --partial "rebased it"
}

@test "a fetch that loses its connection once is tried again" {
  setup_fast_forward
  FETCH_ERROR="$dropped" FETCH_ERROR_TIMES=1 run_merge
  assert_success
  assert_output --partial "Merged #7."
  assert_equal "$(attempts fetch)" 2
}

@test "a fetch that keeps losing its connection fails the run and pushes nothing" {
  setup_fast_forward
  FETCH_ERROR="$dropped" run_merge
  assert_failure
  assert_output --partial "$dropped"
  assert_equal "$(attempts fetch)" 3
  run cat "$MERGE_LOG"
  refute_output --partial "push "
}

@test "a head branch push that loses its connection once is tried again for linearise and rebase" {
  for effect in linearise rebase; do
    : >"$MERGE_LOG"
    THEN=$effect MERGE_METHOD= MERGE_TOKEN= SSH_KEY=key WHEN="label: automerge" HEAD_SHA=abc \
      MERGE_COMMITS="$([ "$effect" = rebase ] || echo m1)" BASE_MOVED=1 PUSH_ERROR="$dropped" PUSH_ERROR_TIMES=1 run_merge
    assert_success
    assert_output --partial "rebased it"
    assert_equal "$(attempts push)" 2
  done
}

@test "a head branch push that keeps failing fails the run and reports no rebase" {
  THEN=rebase MERGE_METHOD= MERGE_TOKEN= SSH_KEY=key WHEN="label: automerge" BASE_MOVED=1 PUSH_ERROR="$dropped" run_merge
  assert_failure
  assert_output --partial "$dropped"
  refute_output --partial "rebased it"
}
