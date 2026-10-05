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

| Condition          | Holds when                                                                                                                                                                          |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `label: <name>`    | the pull request carries the label                                                                                                                                                  |
| `check: <name>`    | a check run of that name succeeded on the head commit. Point it at one aggregate job that `needs` every other job and runs with `if: always()`, so it passes only when they all did |
| `threads-resolved` | no review thread is unresolved (more than 100 threads counts as unresolved)                                                                                                         |
| `not-draft`        | the pull request is ready for review                                                                                                                                                |
| `approvals: <n>`   | at least `n` reviewers' latest review is an approval and none requests changes                                                                                                      |
| `author: <a>, <b>` | the author's login is one of those listed, such as `dependabot[bot]`                                                                                                                |
| `base: <branch>`   | the pull request targets that branch                                                                                                                                                |

## Credentials

How the merge is made decides which credential you give. At most one of `merge-token`, `app-id` and `ssh-key`.

| Method                                        | Credential                                                                                                                                                                                                                       |
| --------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `rebase`, `squash`, `merge` (through the API) | `merge-token`, a personal access token or a GitHub App installation token, or `app-id` with `app-private-key`, which mints an installation token for the repository (the app needs read and write on contents and pull requests) |
| `fast-forward`                                | any of the above, pushing over HTTPS, or `ssh-key`, a write deploy key, pushing over SSH                                                                                                                                         |

A deploy key is an SSH key and cannot call the API, so it only works with `fast-forward`. Use a credential other than `GITHUB_TOKEN` when the merge should start workflows (a release on `main`), because GitHub does not start workflows from pushes made with `GITHUB_TOKEN`. A protected base branch needs the credential's identity to be a bypass actor.

`fast-forward` fetches the pull request's head and pushes that exact commit to the base branch, which GitHub records as the pull request being merged. Because it is a push of existing commits, a pull request that is behind its base is not merged (the push is rejected) and is left for its author to update, unless `update-behind: true`: the action then rebases the head branch onto the base and pushes it back with a lease on the head it saw, so CI runs on the new head and a later run merges it. Fork pull requests and rebases that conflict are left alone.

## Inputs

| Input                       | Default             | Meaning                                                                |
| --------------------------- | ------------------- | ---------------------------------------------------------------------- |
| `when`                      | required            | The conditions, above                                                  |
| `merge-method`              | `rebase`            | `rebase`, `squash`, `merge` or `fast-forward`                          |
| `merge-token`               |                     | An API token                                                           |
| `app-id`, `app-private-key` |                     | A GitHub App to mint a token from                                      |
| `ssh-key`                   |                     | A write deploy key, for `fast-forward`                                 |
| `update-behind`             | `false`             | For `fast-forward`, rebase a behind pull request instead of leaving it |
| `read-token`                | `github.token`      | Token used to read pull requests, checks and review threads            |
| `head-sha`                  | event's head commit | Commit to act on                                                       |

## Development

`npm test` runs the [bats](https://bats-core.readthedocs.io) suite for `merge.sh` against fake `gh` and `git` executables and the unit tests for the release plugins, and `npm run shellcheck` lints the script. CI also runs commitlint, actionlint, typecheck, lint and format checks, aggregated into one `Required Checks` job.

This repository merges its own labelled pull requests with the action, using `fast-forward` and the release deploy key (`.github/workflows/merge-when.yml`).

Releases are made by semantic-release from conventional commits on `main`: it tags the version, publishes the GitHub Release with the changelog entry and a full changelog link, and moves the major tag (`v1`) that consumers pin to, with a release of that name carrying the changelog for the whole major version.
