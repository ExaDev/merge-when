import type { Config } from "prettier";

/**
 * singleQuote is already Prettier's own default (false); stated explicitly rather than omitted, since every YAML, JSON, and TypeScript file in this repository is written double-quoted by hand already — an explicit setting says that's a deliberate choice, not an unexamined default a future reader might assume was simply forgotten.
 *
 * proseWrap is left at its own default, preserve: this repository writes prose and YAML comments as one continuous line regardless of length (see the "never hard wrap" convention already followed throughout), and preserve is the one setting that leaves that alone rather than reflowing it at printWidth.
 */
const config: Config = {
  singleQuote: false,
};

export default config;
