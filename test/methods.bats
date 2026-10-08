#!/usr/bin/env bats

load helpers

run_merge() { run "$BATS_TEST_DIRNAME/../merge.sh"; }

@test "rebase passes the method and pins the head commit" {
  run_merge
  assert_success
  run cat "$MERGE_LOG"
  assert_output --partial "--rebase --match-head-commit abc"
}

@test "squash passes its own flag" {
  MERGE_METHOD=squash run_merge
  run cat "$MERGE_LOG"
  assert_output --partial "--squash --match-head-commit abc"
}

@test "an unknown method is rejected" {
  MERGE_METHOD=ff run_merge
  assert_failure
  assert_output --partial "merge-method must be"
}

@test "an API method needs a token" {
  MERGE_TOKEN= run_merge
  assert_failure
  assert_output --partial "merge token is required"
}

@test "an API method refuses an ssh key" {
  SSH_KEY=k run_merge
  assert_failure
  assert_output --partial "only used by merge-method fast-forward"
}

@test "fast-forward with a deploy key pushes the head commit over SSH" {
  MERGE_METHOD=fast-forward MERGE_TOKEN= SSH_KEY=key run_merge
  assert_success
  run cat "$MERGE_LOG"
  assert_output --partial "push git@github.com:o/r.git abc:refs/heads/main"
  refute_output --partial "auth "
}

@test "fast-forward with a token pushes over https with a bearer header, not the token in the URL" {
  MERGE_METHOD=fast-forward run_merge
  assert_success
  run cat "$MERGE_LOG"
  assert_output --partial "push https://github.com/o/r.git abc:refs/heads/main"
  assert_output --partial "auth http.extraheader=AUTHORIZATION: basic "
  refute_output --partial "write"
}

@test "fast-forward needs a credential" {
  MERGE_METHOD=fast-forward MERGE_TOKEN= run_merge
  assert_failure
  assert_output --partial "needs a token or an ssh-key"
}

@test "fast-forward refuses two credentials" {
  MERGE_METHOD=fast-forward SSH_KEY=key run_merge
  assert_failure
  assert_output --partial "not both"
}

@test "fast-forward onto a moved base leaves the pull request alone" {
  MERGE_METHOD=fast-forward PUSH_FAILS=1 run_merge
  assert_success
  assert_output --partial "needs updating first"
  run cat "$MERGE_LOG"
  refute_output --partial "push "
}

@test "update-behind rebases and pushes the head branch with a lease" {
  MERGE_METHOD=fast-forward PUSH_FAILS=1 UPDATE_BEHIND=true run_merge
  assert_output --partial "rebased it"
  run cat "$MERGE_LOG"
  assert_output --partial "HEAD:refs/heads/topic --force-with-lease=refs/heads/topic:abc"
}

@test "update-behind leaves a fork alone" {
  MERGE_METHOD=fast-forward PUSH_FAILS=1 UPDATE_BEHIND=true PR_FORK=true run_merge
  assert_output --partial "comes from a fork"
  run cat "$MERGE_LOG"
  refute_output --partial "push "
}

@test "update-behind pushes nothing when the rebase conflicts" {
  MERGE_METHOD=fast-forward PUSH_FAILS=1 UPDATE_BEHIND=true REBASE_FAILS=1 run_merge
  assert_output --partial "doesn't rebase cleanly"
  run cat "$MERGE_LOG"
  refute_output --partial "push "
}

merged() { [ -s "$MERGE_LOG" ]; }
updated() { [ -s "$UPDATE_LOG" ]; }
cancelled() { [ -s "$CANCEL_LOG" ]; }

failed_run='[{"name":"Required checks","conclusion":"failure"}]'

@test "update-stale is refused for squash, merge and fast-forward" {
  for method in squash merge; do
    MERGE_METHOD=$method UPDATE_STALE=true run_merge
    assert_failure
    assert_output --partial "update-stale is only used by merge-method rebase"
  done
  MERGE_METHOD=fast-forward UPDATE_STALE=true run_merge
  assert_failure
  assert_output --partial "update-stale is only used by merge-method rebase"
}

@test "update-stale rebases a behind pull request whose check failed, pinned to the head it saw" {
  UPDATE_STALE=true BEHIND_BY=3 CHECK_RUNS="$failed_run" run_merge
  assert_success
  assert_output --partial "rebased it"
  run cat "$UPDATE_LOG"
  assert_output --partial "update api repos/o/r/pulls/7/update-branch"
  assert_output --partial "expected_head_sha=abc"
  assert_output --partial "update_method=rebase"
  ! merged
}

@test "update-stale rebases when the check was cancelled" {
  UPDATE_STALE=true BEHIND_BY=1 CHECK_RUNS='[{"name":"Required checks","conclusion":"cancelled"}]' run_merge
  updated
}

@test "update-stale leaves a pull request that isn't behind its base" {
  UPDATE_STALE=true BEHIND_BY=0 CHECK_RUNS="$failed_run" run_merge
  assert_output --partial "isn't behind main"
  ! updated
}

@test "update-stale leaves a pull request whose check is merely pending" {
  UPDATE_STALE=true BEHIND_BY=3 CHECK_RUNS='[{"name":"Required checks","conclusion":null}]' run_merge
  ! updated
}

@test "update-stale never touches a fork" {
  UPDATE_STALE=true BEHIND_BY=3 PR_FORK=true CHECK_RUNS="$failed_run" run_merge
  assert_output --partial "comes from a fork"
  ! updated
}

@test "update-stale leaves a pull request that another condition rejects" {
  UPDATE_STALE=true BEHIND_BY=3 PR_LABEL=other CHECK_RUNS="$failed_run" run_merge
  ! updated
}

@test "update-stale ignores a failing check the conditions don't name" {
  UPDATE_STALE=true BEHIND_BY=3 CHECK_RUNS='[{"name":"Required checks","conclusion":"success"},{"name":"unrelated","conclusion":"failure"}]' run_merge
  merged
  ! updated
}

@test "update-stale acts on a failing no-failing-checks condition, but not on an excepted check" {
  WHEN=$'no-failing-checks: known-red' UPDATE_STALE=true BEHIND_BY=3 CHECK_RUNS='[{"name":"known-red","conclusion":"failure"},{"name":"build","conclusion":"success"}]' run_merge
  merged
  ! updated
  WHEN=$'no-failing-checks: known-red' UPDATE_STALE=true BEHIND_BY=3 CHECK_RUNS='[{"name":"known-red","conclusion":"failure"},{"name":"build","conclusion":"failure"}]' run_merge
  updated
}

@test "update-stale reports a rebase that cannot be made and merges nothing" {
  UPDATE_STALE=true BEHIND_BY=3 UPDATE_FAILS=1 CHECK_RUNS="$failed_run" run_merge
  assert_success
  assert_output --partial "couldn't be rebased"
  ! merged
}

@test "update-stale is off by default" {
  BEHIND_BY=3 CHECK_RUNS="$failed_run" run_merge
  ! updated
}

running_run='[{"id":11,"status":"in_progress","head_repository":{"full_name":"o/r"}},{"id":12,"status":"queued","head_repository":{"full_name":"o/r"}},{"id":13,"status":"in_progress","head_repository":{"full_name":"someone/r"}},{"id":99,"status":"in_progress","head_repository":{"full_name":"o/r"}}]'

@test "cancel-runs cancels the queued and in-progress runs of the merged head, not the current run or a fork's" {
  CANCEL_RUNS=true GITHUB_RUN_ID=99 WORKFLOW_RUNS="$running_run" run_merge
  assert_success
  run cat "$CANCEL_LOG"
  assert_output --partial "runs/11/cancel"
  assert_output --partial "runs/12/cancel"
  refute_output --partial "runs/13/"
  refute_output --partial "runs/99/"
}

@test "cancel-runs is off by default" {
  WORKFLOW_RUNS="$running_run" run_merge
  merged
  ! cancelled
}

@test "cancel-runs cancels nothing when nothing merged" {
  CANCEL_RUNS=true WORKFLOW_RUNS="$running_run" PR_LABEL=other run_merge
  ! cancelled
}

@test "cancel-runs leaves a fork's branch alone" {
  CANCEL_RUNS=true PR_FORK=true WORKFLOW_RUNS="$running_run" run_merge
  merged
  ! cancelled
}

@test "cancel-runs leaves a head branch named like the base alone" {
  CANCEL_RUNS=true PR_BASE=topic WORKFLOW_RUNS="$running_run" WHEN=$'label: automerge' run_merge
  merged
  ! cancelled
}

@test "cancel-runs works with fast-forward too" {
  CANCEL_RUNS=true MERGE_METHOD=fast-forward WORKFLOW_RUNS="$running_run" run_merge
  assert_output --partial "Merged #7."
  cancelled
}

@test "cancel-runs fails the run when a live run cannot be cancelled, after merging everything" {
  CANCEL_RUNS=true CANCEL_FAILS=1 WORKFLOW_RUNS="$running_run" run_merge
  assert_failure
  assert_output --partial "Couldn't cancel run 11"
  merged
}

@test "cancel-runs ignores a run that finished before it could be cancelled" {
  CANCEL_RUNS=true CANCEL_FAILS=1 RUN_STATUS=completed WORKFLOW_RUNS="$running_run" run_merge
  assert_success
}
