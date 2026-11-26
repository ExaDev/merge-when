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
  MERGE_METHOD=fast-forward BASE_MOVED=1 run_merge
  assert_success
  assert_output --partial "needs updating first"
  run cat "$MERGE_LOG"
  refute_output --partial "push "
}

@test "update-behind rebases and pushes the head branch with a lease" {
  MERGE_METHOD=fast-forward BASE_MOVED=1 UPDATE_BEHIND=true run_merge
  assert_output --partial "rebased it"
  run cat "$MERGE_LOG"
  assert_output --partial "HEAD:refs/heads/topic --force-with-lease=refs/heads/topic:abc"
}

@test "update-behind leaves a fork alone" {
  MERGE_METHOD=fast-forward BASE_MOVED=1 UPDATE_BEHIND=true PR_FORK=true run_merge
  assert_output --partial "comes from a fork"
  run cat "$MERGE_LOG"
  refute_output --partial "push "
}

@test "update-behind pushes nothing when the rebase conflicts" {
  MERGE_METHOD=fast-forward BASE_MOVED=1 UPDATE_BEHIND=true REBASE_FAILS=1 run_merge
  assert_output --partial "doesn't rebase cleanly"
  run cat "$MERGE_LOG"
  refute_output --partial "push "
}

@test "fast-forward refuses a pull request with merge commits" {
  MERGE_METHOD=fast-forward MERGE_COMMITS=m1 run_merge
  assert_success
  assert_output --partial "linearise it first, or set allow-merge-commits"
  run cat "$MERGE_LOG"
  refute_output --partial "push "
}

@test "allow-merge-commits fast-forwards a pull request with merge commits" {
  MERGE_METHOD=fast-forward MERGE_COMMITS=m1 ALLOW_MERGE_COMMITS=true run_merge
  assert_success
  run cat "$MERGE_LOG"
  assert_output --partial "abc:refs/heads/main"
}

@test "allow-merge-commits merges the base into a behind pull request instead of rebasing it" {
  MERGE_METHOD=fast-forward MERGE_COMMITS=m1 ALLOW_MERGE_COMMITS=true BASE_MOVED=1 UPDATE_BEHIND=true run_merge
  assert_success
  assert_output --partial "merged main into it"
  run cat "$MERGE_LOG"
  assert_output --partial "merge -q --no-edit refs/remotes/base"
  assert_output --partial "HEAD:refs/heads/topic --force-with-lease=refs/heads/topic:abc"
}

@test "allow-merge-commits pushes nothing when the base does not merge cleanly" {
  MERGE_METHOD=fast-forward MERGE_COMMITS=m1 ALLOW_MERGE_COMMITS=true BASE_MOVED=1 UPDATE_BEHIND=true MERGE_FAILS=1 run_merge
  assert_success
  assert_output --partial "doesn't merge cleanly"
  run cat "$MERGE_LOG"
  refute_output --partial "push "
}

@test "update-behind still rebases a pull request without merge commits when merge commits are allowed" {
  MERGE_METHOD=fast-forward ALLOW_MERGE_COMMITS=true BASE_MOVED=1 UPDATE_BEHIND=true run_merge
  assert_output --partial "rebased it"
  run cat "$MERGE_LOG"
  refute_output --partial "merge -q"
}

@test "allow-merge-commits is rejected outside merge-method fast-forward" {
  MERGE_METHOD=rebase ALLOW_MERGE_COMMITS=true run_merge
  assert_failure
  assert_output --partial "allow-merge-commits is only used by merge-method fast-forward"
}

@test "allow-merge-commits is rejected for then: ready, linearise and rebase" {
  for effect in ready linearise rebase; do
    THEN=$effect MERGE_METHOD= WHEN="label: automerge" ALLOW_MERGE_COMMITS=true run_merge
    assert_failure
    assert_output --partial "allow-merge-commits is only used by then: merge with merge-method fast-forward"
  done
}
