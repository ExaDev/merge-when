import type { Options } from "semantic-release";

type ReleaseLevel = "major" | "minor" | "patch" | false;

interface CommitType {
  readonly type: string;
  readonly release: ReleaseLevel;
}

/**
 * The conventional-commit types this repository accepts, and the release level each one triggers. commitlint.config.ts imports this so its type-enum rule and commit-analyzer's releaseRules below can never drift apart — a commit type either exists here, or it fails commit-msg validation and never reaches a release decision.
 */
export const commitTypes: readonly CommitType[] = [
  { type: "feat", release: "minor" },
  { type: "fix", release: "patch" },
  { type: "docs", release: "patch" },
  { type: "refactor", release: "patch" },
  { type: "perf", release: "patch" },
  { type: "test", release: "patch" },
  { type: "build", release: "patch" },
  { type: "ci", release: "patch" },
  { type: "chore", release: "patch" },
  { type: "revert", release: "patch" },
];

/**
 * Runs on push to main. Analyses commits since the last v* tag, computes the next version, generates release notes and a CHANGELOG.md entry, creates the GitHub Release and the version tag, and commits CHANGELOG.md back to main. There is no npm-publish step: this repository ships a GitHub Action, not an npm package. The final plugin, ./scripts/move-major-tag.mts, moves the moving `v1` tag to the new release afterwards, since semantic-release has no concept of that and consuming repositories already pin to `@v1`.
 */
const config: Options = {
  branches: ["main"],
  // SSH, so the release commit and tags are pushed with the deploy key the checkout configured rather than over https with a token that cannot bypass branch protection.
  repositoryUrl: "git@github.com:ExaDev/merge-when.git",
  plugins: [
    [
      "@semantic-release/commit-analyzer",
      {
        preset: "conventionalcommits",
        releaseRules: [
          { breaking: true, release: "major" },
          ...commitTypes.map((t) => ({ type: t.type, release: t.release })),
        ],
      },
    ],
    // angular, not conventionalcommits: conventional-changelog-writer's bundled commit partial doesn't match the conventionalcommits preset's function-based partial signature, which renders a version header with nothing under it. angular is release-notes-generator's own tested default. commitTypes above still governs which types exist and what they release, regardless of changelog preset.
    [
      "@semantic-release/release-notes-generator",
      {
        preset: "angular",
        // The angular preset's own headerPartial renders the version header as H1 for any minor or major release and H2 only for a patch (`{{#if isPatch}}##{{else}}#{{/if}}`), while every commit-group subheading (Bug Fixes, Features, ...) is always H3. A repo that ever has more than one non-patch release — which this one already does — ends up with more than one H1 and, on each of those releases, an H1-straight-to-H3 skip. Fixed here at the template level rather than by disabling the markdown linter's heading rules for CHANGELOG.md: the version header is always H2, so it is always a valid H2-then-H3 sequence and the file's only real H1 stays this repository's own "# Changelog" title, for every release from now on, not just this one.
        writerOpts: {
          headerPartial: `## {{#if @root.linkCompare~}}
  [{{version}}](
  {{~#if @root.repository~}}
    {{~#if @root.host}}
      {{~@root.host}}/
    {{~/if}}
    {{~#if @root.owner}}
      {{~@root.owner}}/
    {{~/if}}
    {{~@root.repository}}
  {{~else}}
    {{~@root.repoUrl}}
  {{~/if~}}
  /compare/{{previousTag}}...{{currentTag}})
{{~else}}
  {{~version}}
{{~/if}}
{{~#if title}} "{{title}}"
{{~/if}}
{{~#if date}} ({{date}})
{{/if}}
`,
        },
      },
    ],
    "@semantic-release/changelog",
    // A plugin file, not an npm package: runs in the prepare step, which executes in plugin-list order, so placing it here -- after @semantic-release/changelog writes CHANGELOG.md and before @semantic-release/git commits it -- formats the generated file so it passes format:check. See the plugin's own docstring for why this is a local plugin rather than a flag on @semantic-release/changelog (which has none).
    "./scripts/format-changelog.mts",
    "@semantic-release/github",
    [
      "@semantic-release/git",
      {
        assets: ["CHANGELOG.md"],
        message: "chore(release): ${nextRelease.version} [skip ci]",
      },
    ],
    // A plugin file, not an npm dependency: referenced by path so Options.plugins' own PluginSpec type (string | [string, T]) is satisfied without a cast. See the plugin's own docstring for why this exists as local code rather than a package.
    "./scripts/move-major-tag.mts",
    // A plugin file, not an npm dependency, for the same reason. Runs after the tag move so the release it edits points at the moved tag.
    "./scripts/add-compare-link.mts",
    "./scripts/sync-major-release.mts",
  ],
};

export default config;
