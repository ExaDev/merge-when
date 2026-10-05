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
#   MERGE_METHOD  rebase, squash or merge (through the API, with MERGE_TOKEN), or fast-forward (a push of the head commit to the base branch, with MERGE_TOKEN over https or SSH_KEY over SSH)
#   MERGE_TOKEN   an API token: a personal access token or a GitHub App installation token
#   SSH_KEY       the private half of a write deploy key, for fast-forward only
#   UPDATE_BEHIND true to rebase a fast-forward pull request that is behind its base onto it and push the result to its branch (never a fork's), instead of leaving it
set -euo pipefail

: "${WHEN:?when is required}"

case "$MERGE_METHOD" in
  rebase | squash | merge)
    : "${MERGE_TOKEN:?a merge token is required for merge-method $MERGE_METHOD}"
    if [ -n "${SSH_KEY-}" ]; then
      echo "ssh-key is only used by merge-method fast-forward." >&2
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
    "label: "* | "check: "* | "approvals: "* | "author: "* | "base: "* | threads-resolved | not-draft) conditions+=("$line") ;;
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
  esac
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
done
