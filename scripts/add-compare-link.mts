import { execFileSync } from "node:child_process";
import type { SuccessContext } from "semantic-release";

/** semantic-release's own SuccessContext types `logger` as `Signale<...>`, but the `signale` package ships no type declarations of its own, so it surfaces as an unsafe `any` wherever `context.logger` is used. Overriding just that one field with the narrow shape this file calls avoids relying on the broken upstream type. */
type TypedSuccessContext = Omit<SuccessContext, "logger" | "lastRelease"> & {
  readonly logger: { readonly log: (message: string) => void };
  /** semantic-release types `lastRelease` as always carrying a tag, but for the very first release it is an empty object. */
  readonly lastRelease: { readonly gitTag?: string };
};

/**
 * semantic-release plugin, referenced by path from release.config.ts. Appends a "Full Changelog" link, the compare view from the previous release to this one, below the changelog entry in the release semantic-release just published. GitHub's generated "What's Changed" list is left out on purpose: the entry already lists the commits.
 *
 * Runs in the `success` step, after the release exists. The first release has nothing to compare against and is left as it is.
 */
export function success(
  _pluginConfig: unknown,
  context: TypedSuccessContext,
): void {
  const { nextRelease, lastRelease, logger, cwd, env } = context;

  const gh = (...args: readonly string[]): string =>
    execFileSync("gh", args, {
      cwd,
      env,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "inherit"],
    });

  if (lastRelease.gitTag === undefined) {
    logger.log(`No earlier release to compare ${nextRelease.gitTag} with`);
    return;
  }

  const repoUrl = gh("repo", "view", "--json", "url", "--jq", ".url").trim();
  const changelog = gh(
    "release",
    "view",
    nextRelease.gitTag,
    "--json",
    "body",
    "--jq",
    ".body",
  ).trim();
  const link = `**Full Changelog**: ${repoUrl}/compare/${lastRelease.gitTag}...${nextRelease.gitTag}`;

  gh(
    "release",
    "edit",
    nextRelease.gitTag,
    "--notes",
    `${changelog}\n\n${link}`,
  );
  logger.log(`Added the full changelog link to ${nextRelease.gitTag}`);
}
