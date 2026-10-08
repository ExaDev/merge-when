# merge-when

Merges a pull request once conditions you list all hold, without relying on GitHub's own auto-merge or branch protection. [`merge-when-green`](https://github.com/ExaDev/merge-when-green) is this action with the conditions for "labelled, green and discussed" filled in.

## When to use this

- **A private repository on the Free plan**, where GitHub offers neither auto-merge nor required status checks.
- **A repository where auto-merge is switched off**, by a repository or organisation setting you can't or won't change.
- **Merge rules kept in a workflow rather than in settings**: wait for one aggregate check on the exact head commit, for every review thread to be resolved, for approvals, or for a particular author, whichever plan the repository is on.
- **A setup with no personal access token to hand out**: a GitHub App or a deploy key can do the merge instead.

Where GitHub's native auto-merge with required checks is available and does what you need, use that. Nothing here stops anyone merging by hand; the action only saves waiting.

## Use

The action has no triggers of its own, so a workflow supplies them. Run it when CI finishes, and again when the label is added or the pull request leaves draft, so a pull request that already meets the conditions merges at once.

```yaml
name: Merge when

on:
  workflow_run:
    workflows: [CI]
    types: [completed]
  pull_request_target:
    types: [labeled, ready_for_review]

concurrency:
  group: merge-when-${{ github.event.workflow_run.head_sha || github.event.pull_request.head.sha }}
  cancel-in-progress: false

permissions:
  contents: read
  pull-requests: read
  checks: read

jobs:
  merge:
    if: >-
      (github.event_name == 'workflow_run' && github.event.workflow_run.event == 'pull_request' && github.event.workflow_run.conclusion == 'success')
      || (github.event_name == 'pull_request_target' && contains(github.event.pull_request.labels.*.name, 'automerge'))
    runs-on: ubuntu-latest
    steps:
      - uses: ExaDev/merge-when@v1
        with:
          merge-token: ${{ secrets.MERGE_TOKEN }}
          when: |
            label: automerge
            check: Required checks
            not-draft
            threads-resolved
```

Do not add a checkout step that fetches pull request code. Running no pull request code is what makes the `pull_request_target` trigger safe.

A pull request is considered only when it still has the commit that triggered the run at its head, and the merge is pinned to that commit, so a push made after the conditions held is never merged unseen.

## Conditions

`when` lists one condition per line, and every line must hold. Blank lines and lines starting with `#` are ignored. An unknown condition fails the run before any pull request is touched, so a typo can't silently drop a safeguard.

| Condition              | Holds when                                                                                                                                                                          |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `label: <name>`        | the pull request carries the label                                                                                                                                                  |
| `check: <name>`        | a check run of that name succeeded on the head commit. Point it at one aggregate job that `needs` every other job and runs with `if: always()`, so it passes only when they all did |
| `threads-resolved`     | no review thread is unresolved (more than 100 threads counts as unresolved)                                                                                                         |
| `not-draft`            | the pull request is ready for review                                                                                                                                                |
| `approvals: <n>`       | at least `n` reviewers' latest review is an approval and none requests changes                                                                                                      |
| `author: <a>, <b>`     | the author's login is one of those listed, such as `dependabot[bot]`                                                                                                                |
| `base: <branch>`       | the pull request targets that branch                                                                                                                                                |
| `no-failing-checks`    | every check run on the head commit has finished and none failed, except those listed after a colon (`no-failing-checks: lint, e2e`). See [Checks and reviews](#checks-and-reviews)  |
| `bot-review: <marker>` | a bot's comment containing the marker reports a completed review of the head commit. See [Checks and reviews](#checks-and-reviews)                                                  |

### Checks and reviews

`check: <name>` waits for one named check. Use `no-failing-checks` when the rule is the opposite: everything is green, except a short list of checks you name, such as one that is known to be red for a reason outside the pull request. A check run counts as failed when it concluded with anything but `success`, `neutral` or `skipped` (so `failure`, `timed_out`, `cancelled`, `action_required`, `startup_failure` and `stale` all count). A check that has not finished yet does not count as passing: the condition holds only once every check that is not listed has concluded, so the run that merges is the one after the last check finishes. A commit with no check runs at all does not hold either, since its checks may simply not have been created yet. Only check runs are read, not the older commit statuses. Pair it with `check:` on an aggregate job when some checks may be created late.

`bot-review: <marker>` is for a review bot that keeps one summary comment on the pull request. The marker is any string that appears in that comment (an HTML comment such as `my-bot-review-summary`). The comment must be written by a bot account, so a person quoting the marker does not satisfy it. The head commit comes from a `"headSha":"<hash>"` field and the state from a `"status":"<state>"` field in the comment, wherever they sit in it, as bots that embed their state as JSON write them. The condition holds when the newest such comment for the pull request's head commit says `completed`. The hash may be abbreviated, but only as a prefix of the head commit of at least seven characters. A comment for another commit, or one that says `running`, does not hold, and a review started again on the same commit holds the condition back until it completes. The condition fails if no comment matches, so name the marker exactly.

```yaml
when: |
  label: automerge
  check: Required checks
  no-failing-checks: Coverage
  bot-review: my-bot-review-summary
```

## Credentials

How the merge is made decides which credential you give. At most one of `merge-token`, `app-id` and `ssh-key`.

| Method                                        | Credential                                                                                                                                                                                                                       |
| --------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `rebase`, `squash`, `merge` (through the API) | `merge-token`, a personal access token or a GitHub App installation token, or `app-id` with `app-private-key`, which mints an installation token for the repository (the app needs read and write on contents and pull requests) |
| `fast-forward`                                | any of the above, pushing over HTTPS, or `ssh-key`, a write deploy key, pushing over SSH                                                                                                                                         |

A deploy key is an SSH key and cannot call the API, so it only works with `fast-forward`. Use a credential other than `GITHUB_TOKEN` when the merge should start workflows (a release on `main`), because GitHub does not start workflows from pushes made with `GITHUB_TOKEN`. A protected base branch needs the credential's identity to be a bypass actor.

`fast-forward` fetches the pull request's head and pushes that exact commit to the base branch, which GitHub records as the pull request being merged. Because it is a push of existing commits, a pull request that is behind its base is not merged (the push is rejected) and is left for its author to update, unless `update-behind: true`: the action then rebases the head branch onto the base and pushes it back with a lease on the head it saw, so CI runs on the new head and a later run merges it. Fork pull requests and rebases that conflict are left alone.

## After a decision

Both options are off by default.

`cancel-runs: true` cancels, after a successful merge, the queued and in-progress workflow runs of the merged pull request's head commit on its head branch, which would otherwise keep holding runners. The run that is executing the action, runs of a fork's branch of the same name, and a head branch with the same name as the base are left alone. It needs `actions: write` on `read-token` (add `actions: write` to the workflow's `permissions`), and works with every merge method. If a run cannot be cancelled and is still going, the step fails after every pull request has been handled.

`update-stale: true` is for `merge-method: rebase`, where `update-behind` does not apply. A pull request's checks run on a merge ref that GitHub computes from the head and the base at the time, and rerunning them reuses it, so a pull request whose checks failed or were cancelled while its base was behind can only pick up fixes merged since by being brought up to date. With the option on, a pull request that is behind its base, comes from the same repository, has every other condition holding and has a failed or cancelled run among the checks that `check:` and `no-failing-checks` read (never an unrelated check) is rebased onto its base through the `update-branch` API with `update_method=rebase`. Its CI then runs on the new head and a later run merges it. The call carries `expected_head_sha`, so it only succeeds if the branch is still at the commit the conditions were read at, which keeps the head pin intact: this run never merges the pull request it rebased, and the merge of the new head is pinned to the new head by the run that sees its checks pass. A conflict, a moved head and a fork are left alone and reported. The credential needs write access to contents and pull requests (`merge-token`, or `app-id`); an `ssh-key` cannot call the API, and with `rebase` is not accepted anyway. The credential must not be `GITHUB_TOKEN` if the new head's CI is to start, for the same reason as for merging. The workflow also has to run the action when CI fails or is cancelled, which the example above filters out:

```yaml
on:
  workflow_run:
    workflows: [CI]
    types: [completed]
jobs:
  merge:
    if: github.event_name == 'workflow_run' && github.event.workflow_run.event == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: ExaDev/merge-when@v1
        with:
          merge-token: ${{ secrets.MERGE_TOKEN }}
          update-stale: true
          cancel-runs: true
          when: |
            label: automerge
            check: Required checks
```

## Inputs

| Input                       | Default             | Meaning                                                                          |
| --------------------------- | ------------------- | -------------------------------------------------------------------------------- |
| `when`                      | required            | The conditions, above                                                            |
| `merge-method`              | `rebase`            | `rebase`, `squash`, `merge` or `fast-forward`                                    |
| `merge-token`               |                     | An API token                                                                     |
| `app-id`, `app-private-key` |                     | A GitHub App to mint a token from                                                |
| `ssh-key`                   |                     | A write deploy key, for `fast-forward`                                           |
| `update-behind`             | `false`             | For `fast-forward`, rebase a behind pull request instead of leaving it           |
| `update-stale`              | `false`             | For `rebase`, rebase a behind pull request whose checks failed or were cancelled |
| `cancel-runs`               | `false`             | After a merge, cancel the merged head commit's queued and running workflow runs  |
| `read-token`                | `github.token`      | Token used to read pull requests, checks and review threads                      |
| `head-sha`                  | event's head commit | Commit to act on                                                                 |

## Development

`npm test` runs the [bats](https://bats-core.readthedocs.io) suite for `merge.sh` against fake `gh` and `git` executables and the unit tests for the release plugins, and `npm run shellcheck` lints the script. CI also runs commitlint, actionlint, typecheck, lint and format checks, aggregated into one `Required Checks` job.

This repository merges its own labelled pull requests with the action, using `fast-forward` and the release deploy key (`.github/workflows/merge-when.yml`).

Releases are made by semantic-release from conventional commits on `main`: it tags the version, publishes the GitHub Release with the changelog entry and a full changelog link, and moves the major tag (`v1`) that consumers pin to, with a release of that name carrying the changelog for the whole major version.
