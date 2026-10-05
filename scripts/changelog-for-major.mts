/**
 * The entries of a generated CHANGELOG.md that belong to one major version, newest first and in the file's own wording. An entry starts at a level-two heading whose version is `[1.2.3](compare-link)` or a bare `1.2.3`, and runs to the next level-two heading; the file's title and any text before the first entry are not part of any version.
 */
export function changelogForMajor(
  changelog: string,
  major: number,
): readonly string[] {
  return changelog
    .split(/^(?=## )/m)
    .filter((section) => {
      const version = /^## \[?(\d+)\./.exec(section);
      return version?.[1] === String(major);
    })
    .map((section) => section.trim());
}
