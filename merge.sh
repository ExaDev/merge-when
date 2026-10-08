#!/usr/bin/env bash
# Merges each open pull request that has $HEAD_SHA at its head and satisfies every condition in $WHEN.
#
# Inputs (environment):
#   GH_TOKEN      reads pull requests, checks and review threads
#   REPO          owner/name
#   HEAD_SHA      the commit the triggering event is about
#   WHEN          one condition per line (blank lines and lines starting with # are ignored):
#                   label: <name>        the pull request carries the label
#                   check: <name>        a check run of that name succeeded on the head commit
#                   threads-resolved     no review thread is unresolved
#                   not-draft            the pull request is ready for review
#                   approvals: <n>       at least n approvals and no outstanding request for changes
#                   author: <a>, <b>     the author's login is one of those listed
#                   base: <branch>       the pull request targets that branch
#                   bot-review: <marker> a bot's comment containing the marker reports a completed review of the head commit
#                   no-failing-checks[: <a>, <b>]
#                                        every check run on the head commit has concluded and none failed, except those named
#   MERGE_METHOD  rebase, squash or merge (through the API, with MERGE_TOKEN), or fast-forward (a push of the head commit to the base branch, with MERGE_TOKEN over https or SSH_KEY over SSH)
#   MERGE_TOKEN   an API token: a personal access token or a GitHub App installation token
#   SSH_KEY       the private half of a write deploy key, for fast-forward only
#   UPDATE_BEHIND true to rebase a fast-forward pull request that is behind its base onto it and push the result to its branch (never a fork's), instead of leaving it
#   UPDATE_STALE  true to rebase a rebase-method pull request that is behind its base and has a failed or cancelled check, through the update-branch API pinned to the head commit seen (never a fork's), instead of leaving it
#   CANCEL_RUNS   true to cancel the queued and in-progress workflow runs of a merged pull request's head commit (needs actions: write on GH_TOKEN)
set -euo pipefail

: "${WHEN:?when is required}"

case "$MERGE_METHOD" in
  rebase | squash | merge)
    : "${MERGE_TOKEN:?a merge token is required for merge-method $MERGE_METHOD}"
    if [ -n "${SSH_KEY-}" ]; then
      echo "ssh-key is only used by merge-method fast-forward." >&2
      exit 1
    fi
    if [ "${UPDATE_STALE-}" = true ] && [ "$MERGE_METHOD" != rebase ]; then
      echo "update-stale is only used by merge-method rebase." >&2
      exit 1
    fi
    ;;
  fast-forward)
    if [ -n "${MERGE_TOKEN-}" ] && [ -n "${SSH_KEY-}" ]; then
      echo "Give fast-forward one credential, a token or an ssh-key, not both." >&2
      exit 1
    fi
    if [ -z "${MERGE_TOKEN-}" ] && [ -z "${SSH_KEY-}" ]; then
      echo "merge-method fast-forward needs a token or an ssh-key." >&2
      exit 1
    fi
    if [ "${UPDATE_STALE-}" = true ]; then
      echo "update-stale is only used by merge-method rebase." >&2
      exit 1
    fi
    ;;
  *)
    echo "merge-method must be rebase, squash, merge or fast-forward, not \"$MERGE_METHOD\"." >&2
    exit 1
    ;;
esac

# Every line must be a known condition, checked before any pull request is touched, so a typo fails the run instead of silently dropping a safeguard.
conditions=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  case "$line" in
    "" | "#"*) continue ;;
    "label: "* | "check: "* | "approvals: "* | "author: "* | "base: "* | "bot-review: "* | "no-failing-checks: "* | no-failing-checks | threads-resolved | not-draft) conditions+=("$line") ;;
    *)
      echo "Unknown condition: \"$line\"." >&2
      exit 1
      ;;
  esac
done <<<"$WHEN"
if [ "${#conditions[@]}" = 0 ]; then
  echo "when has no conditions." >&2
  exit 1
fi

owner="${REPO%%/*}"
name="${REPO##*/}"

# Prints a JSON summary {failed, pending, total} of the check runs on the head commit. With mode "only" $2 lists the check names considered; with mode "except" every check is considered but the names in $2. failed holds the names of runs that concluded badly (anything but success, neutral or skipped), pending those without a conclusion yet. total counts every run on the commit, before $2 applies.
check_summary() {
  gh api "repos/$REPO/commits/$HEAD_SHA/check-runs" --method GET --paginate -F per_page=100 \
    | jq -s --arg mode "$1" --arg names "$2" '
        ($names | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))) as $listed
        | [.[].check_runs[]] as $all
        | [$all[] | select((.name as $n | $listed | index($n) != null) == ($mode == "only"))] as $runs
        | {
            failed: [$runs[] | select(.conclusion != null and (.conclusion | IN("success", "neutral", "skipped") | not)) | .name],
            pending: [$runs[] | select(.conclusion == null) | .name],
            total: ($all | length)
          }'
}

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
    "bot-review: "*)
      # Only a comment by a bot account counts, so a pull request's author cannot satisfy the condition by pasting the marker. The newest comment for the head commit decides, so a review started again on the same commit holds the condition back until it completes. The head commit is matched as a prefix, since a bot may print an abbreviated hash.
      local review
      review=$(gh api "repos/$REPO/issues/$number/comments" --paginate | jq -r -s --arg marker "$value" --arg head "$HEAD_SHA" '
        [.[][]
          | select(.user.type == "Bot" and ((.body // "") | contains($marker)))
          | {
              sha: ([(.body // "") | scan("\"headSha\"\\s*:\\s*\"([0-9a-fA-F]{7,40})\"")][0][0] // null),
              status: ([(.body // "") | scan("\"status\"\\s*:\\s*\"([a-z_]+)\"")][0][0] // "unknown")
            }
          | select(.sha != null) | . as $c | select(($head | ascii_downcase) | startswith($c.sha | ascii_downcase))]
        | if length == 0 then "none" else (last | .status) end')
      case "$review" in
        completed) ;;
        none) reason="has no \"$value\" review of $HEAD_SHA yet"; return 1 ;;
        *) reason="has a \"$value\" review of $HEAD_SHA that is $review, not completed"; return 1 ;;
      esac
      ;;
    no-failing-checks | "no-failing-checks: "*)
      local summary failed pending listed=""
      [ "$condition" = no-failing-checks ] || listed="$value"
      summary=$(check_summary except "$listed")
      failed=$(jq -r '.failed | join(", ")' <<<"$summary")
      pending=$(jq -r '.pending | join(", ")' <<<"$summary")
      [ "$(jq -r '.total' <<<"$summary")" != 0 ] || { reason="has no check runs on $HEAD_SHA yet"; return 1; }
      [ -z "$failed" ] || { reason="has failed check(s) on $HEAD_SHA: $failed"; return 1; }
      [ -z "$pending" ] || { reason="has check(s) on $HEAD_SHA that haven't finished: $pending"; return 1; }
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
  esac
}

# Run after a condition fails for pull request $1, whose JSON is $2, when update-stale is on. Only a pull request whose every other condition holds and whose check, or no-failing-checks, condition has a run that failed or was cancelled is considered, so a pull request that isn't wanted merged is never touched. If it is behind its base, the update-branch API rebases it onto the base, pinned with expected_head_sha to the commit these conditions were read at, so a push made meanwhile is never rewritten; the merge itself is never made here, since the new head has to pass its own checks and its own run merges it.
update_stale() {
  local number="$1" pr="$2" condition value failed="" summary base behind
  for condition in "${conditions[@]}"; do
    value="${condition#*: }"
    case "$condition" in
      "check: "*) summary=$(check_summary only "$value") ;;
      no-failing-checks) summary=$(check_summary except "") ;;
      "no-failing-checks: "*) summary=$(check_summary except "$value") ;;
      *)
        holds "$condition" "$number" "$pr" || return 0
        continue
        ;;
    esac
    failed+=$(jq -r '.failed | join(", ")' <<<"$summary")
  done
  [ -n "$failed" ] || return 0
  if [ "$(jq -r '.isCrossRepository' <<<"$pr")" = "true" ]; then
    echo "#$number has failed check(s) ($failed) but comes from a fork, so its branch can't be updated."
    return 0
  fi
  base=$(jq -r '.baseRefName' <<<"$pr")
  behind=$(gh api "repos/$REPO/compare/$base...$HEAD_SHA" --method GET -F per_page=1 --jq '.behind_by')
  if [ "$behind" = 0 ]; then
    echo "#$number has failed check(s) ($failed) but isn't behind $base, so updating it wouldn't change what they ran against."
    return 0
  fi
  if GH_TOKEN="$MERGE_TOKEN" gh api "repos/$REPO/pulls/$number/update-branch" --method PUT -f expected_head_sha="$HEAD_SHA" -f update_method=rebase >/dev/null; then
    echo "#$number has failed check(s) ($failed) and was behind $base; rebased it, and CI will run on the new head."
  else
    echo "#$number has failed check(s) ($failed) and is behind $base, but couldn't be rebased onto it (a conflict, or its head moved); it needs updating by hand."
  fi
}

# Cancels the queued and in-progress workflow runs of pull request $1's head commit, which has been merged and whose results nothing waits on. Runs of other commits on the branch, of a fork's branch of the same name, and this run itself are left alone, and so is a head branch named like the base. Sets cancel_failed when a run could not be cancelled and is still going.
cancel_runs() {
  local number="$1" pr="$2" head_ref base state ids id status
  head_ref=$(jq -r '.headRefName' <<<"$pr")
  base=$(jq -r '.baseRefName' <<<"$pr")
  if [ "$(jq -r '.isCrossRepository' <<<"$pr")" = "true" ] || [ "$head_ref" = "$base" ]; then
    return 0
  fi
  for state in queued in_progress waiting pending requested; do
    ids=$(gh api "repos/$REPO/actions/runs" --method GET --paginate -F per_page=100 -f branch="$head_ref" -f head_sha="$HEAD_SHA" -f status="$state" \
      | jq -r --arg repo "$REPO" --arg self "${GITHUB_RUN_ID-}" '.workflow_runs[] | select(.head_repository.full_name == $repo and (.id | tostring) != $self) | .id')
    for id in $ids; do
      if gh api "repos/$REPO/actions/runs/$id/cancel" --method POST >/dev/null; then
        echo "Cancelled run $id of merged #$number."
      else
        status=$(gh api "repos/$REPO/actions/runs/$id" --jq '.status')
        if [ "$status" != completed ]; then
          echo "Couldn't cancel run $id ($status) of merged #$number." >&2
          cancel_failed=true
        fi
      fi
    done
  done
}

# Sets git_auth (leading options for git) and remote for the fast-forward method's credential.
if [ "$MERGE_METHOD" = fast-forward ]; then
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

pulls=$(gh api "repos/$REPO/commits/$HEAD_SHA/pulls" --jq '.[] | select(.state == "open") | .number')
if [ -z "$pulls" ]; then
  echo "No open pull request has $HEAD_SHA at its head."
  exit 0
fi

cancel_failed=false
for number in $pulls; do
  pr=$(gh pr view "$number" --repo "$REPO" --json headRefOid,headRefName,isCrossRepository,isDraft,labels,baseRefName,author,latestReviews)
  if [ "$(jq -r '.headRefOid' <<<"$pr")" != "$HEAD_SHA" ]; then
    echo "#$number has moved on from $HEAD_SHA; its own CI run decides."
    continue
  fi
  reason=""
  met=true
  for condition in "${conditions[@]}"; do
    if ! holds "$condition" "$number" "$pr"; then
      echo "#$number $reason."
      if [ "${UPDATE_STALE-}" = true ]; then
        update_stale "$number" "$pr"
      fi
      met=false
      break
    fi
  done
  [ "$met" = true ] || continue

  if [ "$MERGE_METHOD" = fast-forward ]; then
    base=$(jq -r '.baseRefName' <<<"$pr")
    work=$(mktemp -d)
    git -C "$work" init -q
    git -C "$work" ${git_auth[@]+"${git_auth[@]}"} fetch -q "$remote" "refs/pull/$number/head"
    if ! git -C "$work" ${git_auth[@]+"${git_auth[@]}"} push -q "$remote" "${HEAD_SHA}:refs/heads/$base"; then
      if [ "${UPDATE_BEHIND-}" != true ]; then
        echo "#$number can't be fast-forwarded onto $base; it needs updating first."
      elif [ "$(jq -r '.isCrossRepository' <<<"$pr")" = "true" ]; then
        echo "#$number is behind $base but comes from a fork, so its branch can't be updated."
      else
        head_ref=$(jq -r '.headRefName' <<<"$pr")
        git -C "$work" ${git_auth[@]+"${git_auth[@]}"} fetch -q "$remote" "refs/heads/$base:refs/remotes/base"
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
  if [ "${CANCEL_RUNS-}" = true ]; then
    cancel_runs "$number" "$pr"
  fi
done
[ "$cancel_failed" = false ] || exit 1
