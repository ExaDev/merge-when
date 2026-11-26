# Shared setup for the merge.sh tests: fake `gh` and `git` executables that answer from the environment and record what would have been merged or pushed.

load "../node_modules/bats-support/load"
load "../node_modules/bats-assert/load"

setup() {
  export STUB_DIR="$BATS_TEST_TMPDIR/bin"
  export MERGE_LOG="$BATS_TEST_TMPDIR/merges"
  mkdir -p "$STUB_DIR"
  : >"$MERGE_LOG"
  install_stubs
  export PATH="$STUB_DIR:$PATH"

  export GH_TOKEN=read REPO=o/r HEAD_SHA=abc THEN=merge MERGE_METHOD=rebase MERGE_TOKEN=write
  export WHEN=$'label: automerge\ncheck: Required checks\nnot-draft\nthreads-resolved'
  unset SSH_KEY UPDATE_BEHIND ALLOW_MERGE_COMMITS RERUN_LOST_RUNNERS RUN_ID
  unset BASE_MOVED HEAD_ON_BASE ANCESTRY_FAILS PUSH_ERROR PUSH_ERROR_TIMES FETCH_ERROR FETCH_ERROR_TIMES
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary"
  : >"$GITHUB_STEP_SUMMARY"
}

install_stubs() {
  cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "api repos/"*"/actions/runs/"*"/rerun-failed-jobs") echo "rerun $2" >>"$MERGE_LOG" ;;
  "api repos/"*"/actions/runs/"*"/attempts/"*"/jobs"*) printf '[{"jobs":%s}]\n' "${RUN_JOBS-[]}" ;;
  "api repos/"*"/actions/runs/"*) echo "${RUN_JSON-{\"conclusion\":\"failure\",\"run_attempt\":1\}}" ;;
  "api repos/"*"/check-runs/"*"/annotations")
    job="${2%/annotations}"
    annotations="ANNOTATIONS_${job##*/}"
    echo "${!annotations-[]}"
    ;;
  "api repos/"*"/pulls") if [ -n "${OPEN_PULLS-7}" ]; then echo "${OPEN_PULLS-7}"; fi ;;
  "api repos/"*"/compare/"*) echo "${BEHIND_BY-0}" ;;
  "api repos/"*"/check-runs") echo "${CHECK_PASSED-1}" ;;
  "api graphql") echo "${UNRESOLVED-0}" ;;
  "pr view")
    printf '{"headRefOid":"%s","headRefName":"topic","baseRefName":"%s","isCrossRepository":%s,"isDraft":%s,"labels":[{"name":"%s"}],"author":{"login":"%s"},"latestReviews":%s}\n' \
      "${PR_HEAD-abc}" "${PR_BASE-main}" "${PR_FORK-false}" "${PR_DRAFT-false}" "${PR_LABEL-automerge}" "${PR_AUTHOR-someone}" "${PR_REVIEWS-[]}"
    ;;
  "pr merge") echo "merge $*" >>"$MERGE_LOG" ;;
  "pr ready") echo "ready $* with $GH_TOKEN" >>"$MERGE_LOG" ;;
  *) echo "unexpected gh call: $*" >&2; exit 99 ;;
esac
STUB
  # Records pushes. BASE_MOVED makes the base hold commits the head lacks, so a push onto it is rejected as GitHub would; HEAD_ON_BASE makes the base already contain the head. PUSH_ERROR and FETCH_ERROR fail that command with the given stderr, every time or only the first PUSH_ERROR_TIMES or FETCH_ERROR_TIMES times.
  cat >"$STUB_DIR/git" <<'STUB'
#!/usr/bin/env bash
shift 2 # -C <dir>
while [ "$1" = -c ]; do
  case "$2" in http.extraheader=*) echo "auth $2" >>"$MERGE_LOG" ;; esac
  shift 2
done
# Fails with stderr $2 while the command $1 has been tried no more than $3 times (always, when $3 is empty).
injected() {
  [ -n "$2" ] || return 0
  echo "attempt $1" >>"$MERGE_LOG"
  if [ -z "$3" ] || [ "$(grep -c "^attempt $1\$" "$MERGE_LOG")" -le "$3" ]; then
    printf '%s\nfatal: Could not read from remote repository.\n' "$2" >&2
    exit 128
  fi
}
case "$1" in
  init | checkout) ;;
  fetch) injected fetch "${FETCH_ERROR-}" "${FETCH_ERROR_TIMES-}" ;;
  rev-list) if [ -n "${MERGE_COMMITS-}" ]; then echo "$MERGE_COMMITS"; fi ;;
  merge-base)
    if [ -n "${ANCESTRY_FAILS-}" ]; then echo "fatal: Not a valid commit name" >&2; exit 128; fi
    if [ "$3" = refs/remotes/base ]; then [ -z "${BASE_MOVED-}" ] || exit 1; else [ -n "${HEAD_ON_BASE-}" ] || exit 1; fi
    ;;
  merge-tree) if [ -n "${MERGE_TREE_FAILS-}" ]; then exit 1; fi; echo "${MERGE_TREE-tree1}" ;;
  rev-parse) echo "${REBASED_TREE-tree1}" ;;
  rebase) if [ -n "${REBASE_FAILS-}" ] && [ "$2" != --abort ]; then exit 1; fi ;;
  merge) echo "merge ${*:2}" >>"$MERGE_LOG"; if [ -n "${MERGE_FAILS-}" ] && [ "$2" != --abort ]; then exit 1; fi ;;
  push)
    injected push "${PUSH_ERROR-}" "${PUSH_ERROR_TIMES-}"
    case "$*" in *refs/heads/main) if [ -n "${BASE_MOVED-}" ]; then echo " ! [rejected] abc -> main (non-fast-forward)" >&2; exit 1; fi ;; esac
    echo "push ${*:3}" >>"$MERGE_LOG"
    ;;
  *) echo "unexpected git call: $*" >&2; exit 99 ;;
esac
STUB
  # The waits between transport attempts take no time here.
  printf '#!/usr/bin/env bash\n' >"$STUB_DIR/sleep"
  chmod +x "$STUB_DIR/gh" "$STUB_DIR/git" "$STUB_DIR/sleep"
}
