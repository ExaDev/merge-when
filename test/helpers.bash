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
  unset SSH_KEY UPDATE_BEHIND
}

install_stubs() {
  cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "api repos/"*"/pulls") if [ -n "${OPEN_PULLS-7}" ]; then echo "${OPEN_PULLS-7}"; fi ;;
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
