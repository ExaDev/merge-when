# Shared setup for the merge.sh tests: fake `gh` and `git` executables that answer from the environment and record what would have been merged or pushed.

load "../node_modules/bats-support/load"
load "../node_modules/bats-assert/load"

setup() {
  export STUB_DIR="$BATS_TEST_TMPDIR/bin"
  export MERGE_LOG="$BATS_TEST_TMPDIR/merges"
  export UPDATE_LOG="$BATS_TEST_TMPDIR/updates"
  export CANCEL_LOG="$BATS_TEST_TMPDIR/cancels"
  mkdir -p "$STUB_DIR"
  : >"$MERGE_LOG"
  : >"$UPDATE_LOG"
  : >"$CANCEL_LOG"
  install_stubs
  export PATH="$STUB_DIR:$PATH"

  export GH_TOKEN=read REPO=o/r HEAD_SHA=abc MERGE_METHOD=rebase MERGE_TOKEN=write
  export WHEN=$'label: automerge\ncheck: Required checks\nnot-draft\nthreads-resolved'
  unset SSH_KEY UPDATE_BEHIND UPDATE_STALE CANCEL_RUNS GITHUB_RUN_ID
}

install_stubs() {
  # Answers like the API: JSON from the environment (CHECK_RUNS, ISSUE_COMMENTS, WORKFLOW_RUNS, RUN_STATUS), filtered by the -f and --jq arguments the script passes, so the script's own jq programs run for real.
  cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
verb="$1" endpoint="$2"
shift 2
jq_expr="" name_filter="" status_filter=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jq_expr="$2"; shift 2 ;;
    -f | -F)
      case "$2" in
        check_name=*) name_filter="${2#check_name=}" ;;
        status=*) status_filter="${2#status=}" ;;
      esac
      shift 2
      ;;
    *) shift ;;
  esac
done
emit() { if [ -n "$jq_expr" ]; then jq -r "$jq_expr" <<<"$1"; else printf '%s\n' "$1"; fi; }
default_checks='[{"name":"Required checks","status":"completed","conclusion":"success"}]'
case "$verb $endpoint" in
  "api repos/"*"/pulls") if [ -n "${OPEN_PULLS-7}" ]; then echo "${OPEN_PULLS-7}"; fi ;;
  "api repos/"*"/check-runs")
    emit "$(jq -c --arg n "$name_filter" '{check_runs: [.[] | select($n == "" or .name == $n)]}' <<<"${CHECK_RUNS-$default_checks}")"
    ;;
  "api repos/"*"/issues/"*"/comments") emit "${ISSUE_COMMENTS-[]}" ;;
  "api repos/"*"/compare/"*) emit "{\"behind_by\":${BEHIND_BY-0}}" ;;
  "api repos/"*"/update-branch")
    if [ -n "${UPDATE_FAILS-}" ]; then exit 1; fi
    echo "update $endpoint $*" >>"$UPDATE_LOG"
    ;;
  "api repos/"*"/actions/runs/"*"/cancel")
    if [ -n "${CANCEL_FAILS-}" ]; then exit 1; fi
    echo "cancel $endpoint" >>"$CANCEL_LOG"
    ;;
  "api repos/"*"/actions/runs/"*) emit "{\"status\":\"${RUN_STATUS-in_progress}\"}" ;;
  "api repos/"*"/actions/runs")
    emit "$(jq -c --arg s "$status_filter" '{workflow_runs: [.[] | select(.status == $s)]}' <<<"${WORKFLOW_RUNS-[]}")"
    ;;
  "api graphql") echo "${UNRESOLVED-0}" ;;
  "pr view")
    printf '{"headRefOid":"%s","headRefName":"topic","baseRefName":"%s","isCrossRepository":%s,"isDraft":%s,"labels":[{"name":"%s"}],"author":{"login":"%s"},"latestReviews":%s}\n' \
      "${PR_HEAD-abc}" "${PR_BASE-main}" "${PR_FORK-false}" "${PR_DRAFT-false}" "${PR_LABEL-automerge}" "${PR_AUTHOR-someone}" "${PR_REVIEWS-[]}"
    ;;
  "pr merge") echo "merge $*" >>"$MERGE_LOG" ;;
  *) echo "unexpected gh call: $verb $endpoint $*" >&2; exit 99 ;;
esac
STUB
  # Records pushes, and fails a push onto the base branch when PUSH_FAILS is set, as a moved base would.
  cat >"$STUB_DIR/git" <<'STUB'
#!/usr/bin/env bash
shift 2 # -C <dir>
while [ "$1" = -c ]; do
  case "$2" in http.extraheader=*) echo "auth $2" >>"$MERGE_LOG" ;; esac
  shift 2
done
case "$1" in
  init | fetch | checkout) ;;
  rebase) if [ -n "${REBASE_FAILS-}" ] && [ "$2" != --abort ]; then exit 1; fi ;;
  push)
    case "$*" in *refs/heads/main) if [ -n "${PUSH_FAILS-}" ]; then exit 1; fi ;; esac
    echo "push ${*:3}" >>"$MERGE_LOG"
    ;;
  *) echo "unexpected git call: $*" >&2; exit 99 ;;
esac
STUB
  chmod +x "$STUB_DIR/gh" "$STUB_DIR/git"
}
