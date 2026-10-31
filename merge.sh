#!/usr/bin/env bash
# Applies $THEN to each open pull request that satisfies every condition in $WHEN: merges it, marks a draft ready for review, rewrites its branch without merge commits, or rebases it onto its base. Merge, ready and linearise consider the pull requests that have $HEAD_SHA at their head; rebase considers every open pull request, each at its own head.
#
# The action's when-core step has already checked WHEN and THEN against this script's vocabulary and failed the run on anything it doesn't know, before this script starts.
#
# Inputs (environment):
#   GH_TOKEN      reads pull requests, checks and review threads
#   REPO          owner/name
#   HEAD_SHA      the commit the triggering event is about; not used by rebase, whose trigger is a push to the base branch
#   WHEN          one condition per line, as when-core outputs them (blank lines and lines starting with # are skipped, so raw input also runs):
#                   label: <name>        the pull request carries the label
#                   check: <name>        a check run of that name succeeded on the head commit
#                   threads-resolved     no review thread is unresolved
#                   not-draft            the pull request is ready for review
#                   approvals: <n>       at least n approvals and no outstanding request for changes
#                   author: <a>, <b>     the author's login is one of those listed
#                   base: <branch>       the pull request targets that branch
#                   behind               the base branch has commits the pull request's head lacks
#   THEN          merge; ready to mark a draft ready for review (with MERGE_TOKEN, never GITHUB_TOKEN, so ready_for_review workflows start); or linearise to rebase a pull request that has merge commits onto its base and push the result to its branch (with MERGE_TOKEN or SSH_KEY, never GITHUB_TOKEN, so CI starts on the new head); or rebase to bring a pull request that is behind its base up to date, with the same credential rule
#   MERGE_METHOD  for merge: rebase (when empty), squash or merge (through the API, with MERGE_TOKEN), or fast-forward (a push of the head commit to the base branch, with MERGE_TOKEN over https or SSH_KEY over SSH); ready takes none
#   MERGE_TOKEN   an API token: a personal access token or a GitHub App installation token
#   SSH_KEY       the private half of a write deploy key, for fast-forward, linearise and rebase only
#   UPDATE_BEHIND true to rebase a fast-forward pull request that is behind its base onto it and push the result to its branch (never a fork's), instead of leaving it
set -euo pipefail

: "${WHEN:?when is required}"
: "${THEN:?then is required}"

fail() {
  echo "$1" >&2
  exit 1
}

conditions=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  case "$line" in
    "" | "#"*) ;;
    *) conditions+=("$line") ;;
  esac
done <<<"$WHEN"
[ "${#conditions[@]}" != 0 ] || fail "when has no conditions."

# Every combination of then with the other inputs is checked here, before any pull request is touched.
case "$THEN" in
  merge)
    MERGE_METHOD="${MERGE_METHOD:-rebase}"
    case "$MERGE_METHOD" in
      rebase | squash | merge)
        : "${MERGE_TOKEN:?a merge token is required for merge-method $MERGE_METHOD}"
        [ -z "${SSH_KEY-}" ] || fail "ssh-key is only used by merge-method fast-forward."
        ;;
      fast-forward)
        { [ -z "${MERGE_TOKEN-}" ] || [ -z "${SSH_KEY-}" ]; } || fail "Give fast-forward one credential, a token or an ssh-key, not both."
        { [ -n "${MERGE_TOKEN-}" ] || [ -n "${SSH_KEY-}" ]; } || fail "merge-method fast-forward needs a token or an ssh-key."
        ;;
      *) fail "merge-method must be rebase, squash, merge or fast-forward, not \"$MERGE_METHOD\"." ;;
    esac
    ;;
  ready)
    # Only a draft can be marked ready, so a not-draft condition would never hold.
    for condition in "${conditions[@]}"; do
      [ "$condition" != not-draft ] || fail "then: ready acts on drafts, so it can't be combined with the not-draft condition."
    done
    [ -z "${MERGE_METHOD-}" ] || fail "merge-method is only used by then: merge."
    [ -z "${SSH_KEY-}" ] || fail "ssh-key is only used by then: merge with merge-method fast-forward."
    [ "${UPDATE_BEHIND-false}" = false ] || fail "update-behind is only used by then: merge with merge-method fast-forward."
    # GitHub starts no workflow from an event caused by GITHUB_TOKEN, so marking a pull request ready with it would never trigger the ready_for_review runs that act on it next.
    [ -n "${MERGE_TOKEN-}" ] || fail "then: ready needs merge-token or app-id, so the ready_for_review event starts workflows, which GITHUB_TOKEN can't."
    ;;
  linearise)
    [ -z "${MERGE_METHOD-}" ] || fail "merge-method is only used by then: merge."
    [ "${UPDATE_BEHIND-false}" = false ] || fail "update-behind is only used by then: merge with merge-method fast-forward."
    { [ -z "${MERGE_TOKEN-}" ] || [ -z "${SSH_KEY-}" ]; } || fail "Give then: linearise one credential, a token or an ssh-key, not both."
    # GitHub starts no workflow from a push made with GITHUB_TOKEN, so the rewritten branch would never get the CI run that decides whether it merges.
    { [ -n "${MERGE_TOKEN-}" ] || [ -n "${SSH_KEY-}" ]; } || fail "then: linearise needs merge-token, app-id or ssh-key, so the push starts CI, which GITHUB_TOKEN can't."
    ;;
  rebase)
    [ -z "${MERGE_METHOD-}" ] || fail "merge-method is only used by then: merge."
    [ "${UPDATE_BEHIND-false}" = false ] || fail "update-behind is only used by then: merge with merge-method fast-forward."
    { [ -z "${MERGE_TOKEN-}" ] || [ -z "${SSH_KEY-}" ]; } || fail "Give then: rebase one credential, a token or an ssh-key, not both."
    # GitHub starts no workflow from a push made with GITHUB_TOKEN, so the rebased branch would never get the CI run that decides whether it merges.
    { [ -n "${MERGE_TOKEN-}" ] || [ -n "${SSH_KEY-}" ]; } || fail "then: rebase needs merge-token, app-id or ssh-key, so the push starts CI, which GITHUB_TOKEN can't."
    ;;
  *) fail "then must be merge, ready, linearise or rebase, not \"$THEN\"." ;;
esac

owner="${REPO%%/*}"
name="${REPO##*/}"

# Sets $reason and returns 1 when a condition doesn't hold for pull request $2, whose JSON is $3.
holds() {
  local condition="$1" number="$2" pr="$3" value
  value="${condition#*: }"
  case "$condition" in
    "label: "*)
      jq -e --arg v "$value" 'any(.labels[]; .name == $v)' <<<"$pr" >/dev/null || { reason="isn't labelled $value"; return 1; }
      ;;
    "check: "*)
      local passed
      passed=$(gh api "repos/$REPO/commits/$HEAD_SHA/check-runs" -f check_name="$value" --method GET \
        --jq '[.check_runs[] | select(.conclusion == "success")] | length')
      [ "$passed" != 0 ] || { reason="\"$value\" hasn't passed on $HEAD_SHA yet"; return 1; }
      ;;
    threads-resolved)
      # More than 100 threads cannot all be seen, so that counts as unresolved rather than risk merging past one.
      local unresolved
      # shellcheck disable=SC2016 # $owner, $name and $number are GraphQL variables, not shell ones.
      unresolved=$(gh api graphql -F owner="$owner" -F name="$name" -F number="$number" -f query='
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              reviewThreads(first: 100) { pageInfo { hasNextPage } nodes { isResolved } }
            }
          }
        }' --jq '.data.repository.pullRequest.reviewThreads
          | if .pageInfo.hasNextPage then 100 else [.nodes[] | select(.isResolved | not)] | length end')
      [ "$unresolved" = 0 ] || { reason="has unresolved review thread(s)"; return 1; }
      ;;
    not-draft)
      [ "$(jq -r '.isDraft' <<<"$pr")" = false ] || { reason="is a draft"; return 1; }
      ;;
    "approvals: "*)
      local approvals blocking
      approvals=$(jq '[.latestReviews[] | select(.state == "APPROVED")] | length' <<<"$pr")
      blocking=$(jq '[.latestReviews[] | select(.state == "CHANGES_REQUESTED")] | length' <<<"$pr")
      { [ "$approvals" -ge "$value" ] && [ "$blocking" = 0 ]; } || { reason="has $approvals approval(s) and $blocking request(s) for changes, not the $value approval(s) needed"; return 1; }
      ;;
    "author: "*)
      jq -e --arg v "$value" '.author.login as $a | ($v | split(",") | map(gsub("^\\s+|\\s+$"; ""))) | index($a) != null' <<<"$pr" >/dev/null \
        || { reason="isn't by $value"; return 1; }
      ;;
    "base: "*)
      [ "$(jq -r '.baseRefName' <<<"$pr")" = "$value" ] || { reason="doesn't target $value"; return 1; }
      ;;
    behind)
      local behind_by base_ref
      base_ref=$(jq -r '.baseRefName' <<<"$pr")
      behind_by=$(gh api "repos/$REPO/compare/$base_ref...$HEAD_SHA" --jq '.behind_by')
      [ "$behind_by" != 0 ] || { reason="isn't behind $base_ref"; return 1; }
      ;;
    # when-core rejects an unknown condition before this script runs; one reaching here must still never hold vacuously.
    *) fail "Unknown condition: \"$condition\"." ;;
  esac
}

# Sets git_auth (leading options for git) and remote for the credential of a push: the fast-forward method's, or a linearised or rebased branch's.
if [ "${MERGE_METHOD-}" = fast-forward ] || [ "$THEN" = linearise ] || [ "$THEN" = rebase ]; then
  if [ -n "${SSH_KEY-}" ]; then
    key_file=$(mktemp)
    trap 'rm -f "$key_file"' EXIT
    chmod 600 "$key_file"
    printf '%s\n' "$SSH_KEY" >"$key_file"
    export GIT_SSH_COMMAND="ssh -i $key_file -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
    remote="git@github.com:$REPO.git"
    git_auth=()
  else
    remote="https://github.com/$REPO.git"
    basic=$(printf 'x-access-token:%s' "$MERGE_TOKEN" | base64 | tr -d '\n')
    git_auth=(-c "http.extraheader=AUTHORIZATION: basic $basic")
  fi
fi

# A push to the base branch moves every open pull request's base but changes no pull request's head, so rebase looks at all of them rather than at those with the triggering commit at their head.
if [ "$THEN" = rebase ]; then
  pulls=$(gh api "repos/$REPO/pulls" --paginate --jq '.[].number')
  if [ -z "$pulls" ]; then
    echo "No open pull request."
    exit 0
  fi
else
  pulls=$(gh api "repos/$REPO/commits/$HEAD_SHA/pulls" --jq '.[] | select(.state == "open") | .number')
  if [ -z "$pulls" ]; then
    echo "No open pull request has $HEAD_SHA at its head."
    exit 0
  fi
fi

for number in $pulls; do
  pr=$(gh pr view "$number" --repo "$REPO" --json headRefOid,headRefName,isCrossRepository,isDraft,labels,baseRefName,author,latestReviews)
  if [ "$THEN" = rebase ]; then
    # The conditions and the lease below are about the head the pull request has now.
    HEAD_SHA=$(jq -r '.headRefOid' <<<"$pr")
  elif [ "$(jq -r '.headRefOid' <<<"$pr")" != "$HEAD_SHA" ]; then
    echo "#$number has moved on from $HEAD_SHA; its own CI run decides."
    continue
  fi
  reason=""
  met=true
  for condition in "${conditions[@]}"; do
    if ! holds "$condition" "$number" "$pr"; then
      echo "#$number $reason."
      met=false
      break
    fi
  done
  [ "$met" = true ] || continue

  if [ "$THEN" = linearise ]; then
    base=$(jq -r '.baseRefName' <<<"$pr")
    head_ref=$(jq -r '.headRefName' <<<"$pr")
    if [ "$(jq -r '.isCrossRepository' <<<"$pr")" = "true" ]; then
      echo "#$number comes from a fork, so its branch can't be rewritten."
      continue
    fi
    work=$(mktemp -d)
    git -C "$work" init -q
    git -C "$work" ${git_auth[@]+"${git_auth[@]}"} fetch -q "$remote" "refs/pull/$number/head" "refs/heads/$base:refs/remotes/base"
    if [ -z "$(git -C "$work" rev-list --merges "refs/remotes/base..$HEAD_SHA")" ]; then
      echo "#$number has no merge commits."
    else
      # A rebase drops the merge commits and replays the rest, so a conflict resolved inside a merge would be lost. The branch is rewritten only when the result has the tree merging the head into the base would give, which is the proof that nothing the merge commits carried was lost.
      if merged=$(git -C "$work" merge-tree --write-tree refs/remotes/base "$HEAD_SHA") &&
        git -C "$work" checkout -q --detach "$HEAD_SHA" &&
        git -C "$work" -c user.name=github-actions[bot] -c user.email=github-actions[bot]@users.noreply.github.com rebase -q refs/remotes/base &&
        [ "$(git -C "$work" rev-parse 'HEAD^{tree}')" = "$merged" ]; then
        git -C "$work" ${git_auth[@]+"${git_auth[@]}"} push -q "$remote" "HEAD:refs/heads/$head_ref" "--force-with-lease=refs/heads/$head_ref:$HEAD_SHA"
        echo "#$number had merge commits; rebased it onto $base, and CI will run on the new head."
      else
        git -C "$work" rebase --abort 2>/dev/null || true
        echo "#$number has merge commits that can't be dropped without changing its content; rebase it onto $base by hand."
      fi
    fi
    rm -rf "$work"
    continue
  fi

  if [ "$THEN" = rebase ]; then
    base=$(jq -r '.baseRefName' <<<"$pr")
    head_ref=$(jq -r '.headRefName' <<<"$pr")
    if [ "$(jq -r '.isCrossRepository' <<<"$pr")" = "true" ]; then
      echo "#$number comes from a fork, so its branch can't be rewritten."
      continue
    fi
    work=$(mktemp -d)
    git -C "$work" init -q
    git -C "$work" ${git_auth[@]+"${git_auth[@]}"} fetch -q "$remote" "refs/pull/$number/head" "refs/heads/$base:refs/remotes/base"
    # A rebase drops merge commits, and a conflict resolved inside one would be lost; linearise is the effect that proves nothing is.
    if [ -n "$(git -C "$work" rev-list --merges "refs/remotes/base..$HEAD_SHA")" ]; then
      echo "#$number has merge commits, which a rebase would drop; linearise it first."
    else
      git -C "$work" checkout -q --detach "$HEAD_SHA"
      if git -C "$work" -c user.name=github-actions[bot] -c user.email=github-actions[bot]@users.noreply.github.com rebase -q refs/remotes/base; then
        git -C "$work" ${git_auth[@]+"${git_auth[@]}"} push -q "$remote" "HEAD:refs/heads/$head_ref" "--force-with-lease=refs/heads/$head_ref:$HEAD_SHA"
        echo "#$number was behind $base; rebased it, and CI will run on the new head."
      else
        git -C "$work" rebase --abort 2>/dev/null || true
        echo "#$number doesn't rebase cleanly onto $base; it needs updating by hand."
      fi
    fi
    rm -rf "$work"
    continue
  fi

  if [ "$THEN" = ready ]; then
    # gh pr ready has no head-commit pin, unlike the merge; a pull request readied wrongly is undone with gh pr ready --undo.
    if [ "$(jq -r '.isDraft' <<<"$pr")" = false ]; then
      echo "#$number is already ready for review."
    else
      GH_TOKEN="$MERGE_TOKEN" gh pr ready "$number" --repo "$REPO"
      echo "Marked #$number ready for review."
    fi
    continue
  fi

  if [ "$MERGE_METHOD" = fast-forward ]; then
    base=$(jq -r '.baseRefName' <<<"$pr")
    work=$(mktemp -d)
    git -C "$work" init -q
    git -C "$work" ${git_auth[@]+"${git_auth[@]}"} fetch -q "$remote" "refs/pull/$number/head" "refs/heads/$base:refs/remotes/base"
    # The push puts the head's own commits on the base branch, merge commits included.
    if [ -n "$(git -C "$work" rev-list --merges "refs/remotes/base..$HEAD_SHA")" ]; then
      echo "#$number has merge commits, which fast-forwarding would put on $base; linearise it first."
      rm -rf "$work"
      continue
    fi
    if ! git -C "$work" ${git_auth[@]+"${git_auth[@]}"} push -q "$remote" "${HEAD_SHA}:refs/heads/$base"; then
      if [ "${UPDATE_BEHIND-}" != true ]; then
        echo "#$number can't be fast-forwarded onto $base; it needs updating first."
      elif [ "$(jq -r '.isCrossRepository' <<<"$pr")" = "true" ]; then
        echo "#$number is behind $base but comes from a fork, so its branch can't be updated."
      else
        head_ref=$(jq -r '.headRefName' <<<"$pr")
        git -C "$work" checkout -q --detach "$HEAD_SHA"
        if git -C "$work" -c user.name=github-actions[bot] -c user.email=github-actions[bot]@users.noreply.github.com rebase -q refs/remotes/base; then
          git -C "$work" ${git_auth[@]+"${git_auth[@]}"} push -q "$remote" "HEAD:refs/heads/$head_ref" "--force-with-lease=refs/heads/$head_ref:$HEAD_SHA"
          echo "#$number was behind $base; rebased it, and CI will run on the new head."
        else
          git -C "$work" rebase --abort
          echo "#$number is behind $base and doesn't rebase cleanly; it needs updating by hand."
        fi
      fi
      rm -rf "$work"
      continue
    fi
    rm -rf "$work"
  else
    GH_TOKEN="$MERGE_TOKEN" gh pr merge "$number" --repo "$REPO" "--$MERGE_METHOD" --match-head-commit "$HEAD_SHA"
  fi
  echo "Merged #$number."
done
