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

# A bot's summary comment: a marker, then the head commit and status inside an HTML comment, as review bots write them. Fields can appear in any order.
bot_comment() { # <user type> <marker> <sha> <status>
  jq -nc --arg type "$1" --arg marker "$2" --arg sha "$3" --arg status "$4" \
    '{user: {type: $type}, body: ("<!-- " + $marker + " -->\n<!-- review:v1 {\"status\":\"" + $status + "\",\"count\":2,\"headSha\":\"" + $sha + "\"} -->\n## Review summary")}'
}

use_head() { export HEAD_SHA=0123456789abcdef0123456789abcdef01234567 PR_HEAD=0123456789abcdef0123456789abcdef01234567; }

@test "bot-review: a completed review of the head commit merges" {
  use_head
  ISSUE_COMMENTS="[$(bot_comment Bot review-summary "$HEAD_SHA" completed)]" WHEN=$'bot-review: review-summary' run_merge
  merged
}

@test "bot-review: an abbreviated head commit is matched as a prefix" {
  use_head
  ISSUE_COMMENTS="[$(bot_comment Bot review-summary 0123456 completed)]" WHEN=$'bot-review: review-summary' run_merge
  merged
}

@test "bot-review: a review that is still running holds back" {
  use_head
  ISSUE_COMMENTS="[$(bot_comment Bot review-summary "$HEAD_SHA" running)]" WHEN=$'bot-review: review-summary' run_merge
  assert_output --partial "is running, not completed"
  ! merged
}

@test "bot-review: a completed review of another commit does not count" {
  use_head
  ISSUE_COMMENTS="[$(bot_comment Bot review-summary fedcba9876543210 completed)]" WHEN=$'bot-review: review-summary' run_merge
  assert_output --partial "has no \"review-summary\" review of $HEAD_SHA yet"
  ! merged
}

@test "bot-review: a hash that is not a prefix of the head commit does not count" {
  use_head
  ISSUE_COMMENTS="[$(bot_comment Bot review-summary 0123456789abcdef0123456789abcdef01234568 completed)]" WHEN=$'bot-review: review-summary' run_merge
  ! merged
}

@test "bot-review: a hash too short to be an abbreviation does not count" {
  use_head
  ISSUE_COMMENTS="[$(bot_comment Bot review-summary 012345 completed)]" WHEN=$'bot-review: review-summary' run_merge
  ! merged
}

@test "bot-review: a comment without the marker does not count" {
  use_head
  ISSUE_COMMENTS="[$(bot_comment Bot another-bot "$HEAD_SHA" completed)]" WHEN=$'bot-review: review-summary' run_merge
  ! merged
}

@test "bot-review: a comment by a person quoting the marker does not count" {
  use_head
  ISSUE_COMMENTS="[$(bot_comment User review-summary "$HEAD_SHA" completed)]" WHEN=$'bot-review: review-summary' run_merge
  ! merged
}

@test "bot-review: the newest comment for the head commit decides" {
  use_head
  ISSUE_COMMENTS="[$(bot_comment Bot review-summary "$HEAD_SHA" completed),$(bot_comment Bot review-summary "$HEAD_SHA" running)]" WHEN=$'bot-review: review-summary' run_merge
  ! merged
}

@test "bot-review: a newer comment for another commit does not hide a completed one for the head" {
  use_head
  ISSUE_COMMENTS="[$(bot_comment Bot review-summary "$HEAD_SHA" completed),$(bot_comment Bot review-summary fedcba9876543210 running)]" WHEN=$'bot-review: review-summary' run_merge
  merged
}

@test "bot-review: no comments at all does not hold" {
  use_head
  WHEN=$'bot-review: review-summary' run_merge
  assert_output --partial "has no \"review-summary\" review"
  ! merged
}

@test "bot-review: a comment with no body does not break the condition" {
  use_head
  ISSUE_COMMENTS='[{"user":{"type":"Bot"},"body":null}]' WHEN=$'bot-review: review-summary' run_merge
  assert_success
  ! merged
}

check_runs() { # name:conclusion pairs; an empty conclusion is a run that hasn't finished
  local pair out=()
  for pair in "$@"; do
    out+=("$(jq -nc --arg n "${pair%%:*}" --arg c "${pair#*:}" '{name: $n, conclusion: (if $c == "" then null else $c end)}')")
  done
  local IFS=,
  echo "[${out[*]}]"
}

@test "no-failing-checks: all checks green merges" {
  CHECK_RUNS="$(check_runs build:success lint:success docs:skipped e2e:neutral)" WHEN=$'no-failing-checks' run_merge
  merged
}

@test "no-failing-checks: a failed check blocks and is named" {
  CHECK_RUNS="$(check_runs build:success lint:failure)" WHEN=$'no-failing-checks' run_merge
  assert_output --partial "has failed check(s) on abc: lint"
  ! merged
}

@test "no-failing-checks: timed out, cancelled and action required count as failed" {
  for conclusion in timed_out cancelled action_required startup_failure stale; do
    CHECK_RUNS="$(check_runs build:success "x:$conclusion")" WHEN=$'no-failing-checks' run_merge
    ! merged
  done
}

@test "no-failing-checks: a named check may fail" {
  CHECK_RUNS="$(check_runs build:success flaky:failure)" WHEN=$'no-failing-checks: flaky' run_merge
  merged
}

@test "no-failing-checks: the exception list is comma separated and trimmed" {
  CHECK_RUNS="$(check_runs build:success flaky:failure slow:cancelled)" WHEN=$'no-failing-checks: flaky ,  slow' run_merge
  merged
}

@test "no-failing-checks: only the named checks are excused" {
  CHECK_RUNS="$(check_runs flaky:failure lint:failure)" WHEN=$'no-failing-checks: flaky' run_merge
  assert_output --partial "failed check(s) on abc: lint"
  ! merged
}

@test "no-failing-checks: a check still running does not hold" {
  CHECK_RUNS="$(check_runs build:success lint:)" WHEN=$'no-failing-checks' run_merge
  assert_output --partial "haven't finished: lint"
  ! merged
}

@test "no-failing-checks: a named check may still be running" {
  CHECK_RUNS="$(check_runs build:success slow:)" WHEN=$'no-failing-checks: slow' run_merge
  merged
}

@test "no-failing-checks: a commit with no check runs does not hold" {
  CHECK_RUNS='[]' WHEN=$'no-failing-checks' run_merge
  assert_output --partial "has no check runs on abc yet"
  ! merged
}

@test "no-failing-checks: a check whose name starts like the condition is not an exception to it" {
  CHECK_RUNS="$(check_runs no-failing-checks-extra:failure)" WHEN=$'no-failing-checks' run_merge
  ! merged
}

@test "near misses of the new condition names are unknown and fail before anything is merged" {
  for typo in 'bot-review' 'bot-review:marker' 'bot-reviews: marker' 'no-failing-check' 'no-failing-checks:flaky' 'no-failing-checks flaky'; do
    WHEN="$typo" run_merge
    assert_failure
    assert_output --partial "Unknown condition"
    ! merged
  done
}
