#!/usr/bin/env bats

load helpers

run_merge() { run "$BATS_TEST_DIRNAME/../merge.sh"; }

@test "linearise rebases a pull request with merge commits and pushes with a lease" {
  THEN=linearise MERGE_METHOD= MERGE_TOKEN= SSH_KEY=key WHEN=$'not-draft' MERGE_COMMITS=m1 run_merge
  assert_success
  assert_output --partial "rebased it onto main"
  run cat "$MERGE_LOG"
  assert_output --partial "HEAD:refs/heads/topic --force-with-lease=refs/heads/topic:abc"
}

@test "linearise leaves a linear pull request alone" {
  THEN=linearise MERGE_METHOD= MERGE_TOKEN= SSH_KEY=key WHEN=$'not-draft' run_merge
  assert_success
  assert_output --partial "has no merge commits"
  run cat "$MERGE_LOG"
  refute_output --partial "push "
}

@test "linearise leaves a fork alone" {
  THEN=linearise MERGE_METHOD= MERGE_TOKEN= SSH_KEY=key WHEN=$'not-draft' MERGE_COMMITS=m1 PR_FORK=true run_merge
  assert_output --partial "comes from a fork"
  run cat "$MERGE_LOG"
  refute_output --partial "push "
}

@test "linearise pushes nothing when the rebase conflicts" {
  THEN=linearise MERGE_METHOD= MERGE_TOKEN= SSH_KEY=key WHEN=$'not-draft' MERGE_COMMITS=m1 REBASE_FAILS=1 run_merge
  assert_output --partial "by hand"
  run cat "$MERGE_LOG"
  refute_output --partial "push "
}

@test "linearise pushes nothing when merging the head into the base conflicts" {
  THEN=linearise MERGE_METHOD= MERGE_TOKEN= SSH_KEY=key WHEN=$'not-draft' MERGE_COMMITS=m1 MERGE_TREE_FAILS=1 run_merge
  assert_output --partial "by hand"
  run cat "$MERGE_LOG"
  refute_output --partial "push "
}

@test "linearise pushes nothing when the rebased tree differs from the merged tree" {
  THEN=linearise MERGE_METHOD= MERGE_TOKEN= SSH_KEY=key WHEN=$'not-draft' MERGE_COMMITS=m1 REBASED_TREE=other run_merge
  assert_output --partial "by hand"
  run cat "$MERGE_LOG"
  refute_output --partial "push "
}

@test "linearise needs a credential that starts workflows" {
  THEN=linearise MERGE_METHOD= MERGE_TOKEN= SSH_KEY= WHEN=$'not-draft' run_merge
  assert_failure
  assert_output --partial "GITHUB_TOKEN"
}

@test "linearise refuses two credentials and merge settings" {
  THEN=linearise MERGE_METHOD= SSH_KEY=key WHEN=$'not-draft' run_merge
  assert_failure
  assert_output --partial "not both"
  THEN=linearise MERGE_METHOD=rebase MERGE_TOKEN= SSH_KEY=key WHEN=$'not-draft' run_merge
  assert_failure
  assert_output --partial "only used by then: merge"
}
