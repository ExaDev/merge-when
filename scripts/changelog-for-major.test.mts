import assert from "node:assert/strict";
import { test } from "node:test";
import { changelogForMajor } from "./changelog-for-major.mts";

/** A major version that no entry in the sample changelog belongs to. */
const majorWithNoEntries = 3;

const changelog = `# Changelog

## [2.0.0](https://example.com/compare/v1.1.0...v2.0.0) (2026-02-01)

### Breaking

- dropped a thing

## [1.1.0](https://example.com/compare/v1.0.0...v1.1.0) (2026-01-02)

### Features

- added a thing

## 1.0.0 (2026-01-01)

### Features

- first
`;

await test("collects every entry of the major, newest first", () => {
  const entries = changelogForMajor(changelog, 1);
  assert.equal(entries.length, 2);
  assert.match(entries[0] ?? "", /^## \[1\.1\.0\]/);
  assert.match(entries[1] ?? "", /^## 1\.0\.0/);
});

await test("leaves out other majors and the file title", () => {
  const entries = changelogForMajor(changelog, 2);
  assert.equal(entries.length, 1);
  assert.doesNotMatch(entries.join("\n"), /Changelog\n|added a thing/);
});

await test("a major with no entries gives none", () => {
  assert.deepEqual(changelogForMajor(changelog, majorWithNoEntries), []);
});
