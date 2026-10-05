import { readFile, writeFile } from "node:fs/promises";
import * as prettier from "prettier";
import { join } from "node:path";
import type { PrepareContext } from "semantic-release";

/** semantic-release's own PrepareContext types `logger` as `Signale<...>`, but the `signale` package ships no type declarations of its own (no `main`/`types` entry, no separate `@types/signale`) -- `skipLibCheck` hides the resulting unresolved type from `tsc`, but it still surfaces as an unsafe `any` wherever `context.logger` is actually used. Overriding just that one field with the narrow, honest shape this file actually calls avoids relying on the broken upstream type at all. */
type TypedPrepareContext = Omit<PrepareContext, "logger"> & {
  readonly logger: { readonly log: (message: string) => void };
};

/**
 * semantic-release plugin, referenced by path from release.config.ts. Runs Prettier over CHANGELOG.md after `@semantic-release/changelog` has generated it and before `@semantic-release/git` commits it, so the committed changelog always satisfies this repository's format:check job.
 *
 * Without this, conventional-changelog-writer's output (asterisk bullets, double blank lines between commit groups) fails `prettier --check CHANGELOG.md`, and since the release commit is `[skip ci]` the failure surfaces only on the *next* push to main — by which point a broken CHANGELOG is already on the branch and blocking the subsequent release. Formatting at generation time is the root-cause fix; excluding CHANGELOG.md from Prettier would only hide the mismatch.
 *
 * Runs in the `prepare` step, so it must be listed after `@semantic-release/changelog` (which writes the file) and before `@semantic-release/git` (which commits it) in release.config.ts's plugin order.
 *
 * Uses Prettier's programmatic API with the `filepath` option so it resolves and applies prettier.config.ts exactly as the CLI `prettier --write` would, including the double-quote setting.
 */
export async function prepare(
  _pluginConfig: unknown,
  context: TypedPrepareContext,
): Promise<void> {
  const { cwd, logger } = context;
  const filePath = join(cwd ?? process.cwd(), "CHANGELOG.md");
  const text = await readFile(filePath, "utf8");
  const formatted = await prettier.format(text, { filepath: "CHANGELOG.md" });
  await writeFile(filePath, formatted);
  logger.log("Formatted CHANGELOG.md with Prettier");
}
