import { execFileSync } from "node:child_process";
import type { SuccessContext } from "semantic-release";

/** semantic-release's own SuccessContext types `logger` as `Signale<...>`, but the `signale` package ships no type declarations of its own (no `main`/`types` entry, no separate `@types/signale`) -- `skipLibCheck` hides the resulting unresolved type from `tsc`, but it still surfaces as an unsafe `any` wherever `context.logger` is actually used. Overriding just that one field with the narrow, honest shape this file actually calls avoids relying on the broken upstream type at all. */
type TypedSuccessContext = Omit<SuccessContext, "logger"> & {
  readonly logger: { readonly log: (message: string) => void };
};

/**
 * semantic-release plugin, referenced by path from release.config.ts. Moves the moving major-version tag (v1, v2, ...) to the commit semantic-release just tagged. Consuming repositories pin `@v1` rather than an exact `v1.x.y`, so every release within v1 needs this. No official or third-party semantic-release plugin does this — it is specific to a GitHub-Actions-consumer convention, not the npm/package-semver versioning semantic-release itself models — so it is a small local plugin rather than a dependency.
 *
 * Runs in the `success` step, after every publish plugin has completed, so `nextRelease.gitTag` is already created and pushed by the time this runs.
 */
export function success(
  _pluginConfig: unknown,
  context: TypedSuccessContext,
): void {
  const { nextRelease, logger, cwd, env } = context;
  const majorVersionSegment = nextRelease.version.split(".")[0];
  if (majorVersionSegment === undefined) {
    throw new Error(
      `Could not parse a major version from "${nextRelease.version}".`,
    );
  }
  const major = `v${majorVersionSegment}`;

  const run = (...args: readonly string[]): Buffer =>
    execFileSync("git", args, { cwd, env, stdio: "inherit" });

  // -c user.name/user.email rather than relying on the checkout having git identity configured: creating an annotated tag object requires one, and a fresh CI checkout has none by default. Scoped to this one command rather than writing global git config.
  run(
    "-c",
    "user.name=github-actions[bot]",
    "-c",
    "user.email=github-actions[bot]@users.noreply.github.com",
    "tag",
    "-f",
    "-a",
    major,
    "-m",
    `${major}: moving major tag, currently ${nextRelease.gitTag}`,
    nextRelease.gitTag,
  );
  run("push", "origin", major, "--force");

  logger.log(`Moved ${major} to ${nextRelease.gitTag}`);
}
