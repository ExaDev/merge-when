## [1.5.3](https://github.com/ExaDev/merge-when/compare/v1.5.2...v1.5.3) (2026-11-26)

## [1.5.2](https://github.com/ExaDev/merge-when/compare/v1.5.1...v1.5.2) (2026-11-26)

## [1.5.1](https://github.com/ExaDev/merge-when/compare/v1.5.0...v1.5.1) (2026-11-26)

### Bug Fixes

- tell a failed push apart from a pull request behind its base ([c3aa167](https://github.com/ExaDev/merge-when/commit/c3aa1672097a9111eec0332f344040865afe25bf))

## [1.5.0](https://github.com/ExaDev/merge-when/compare/v1.4.0...v1.5.0) (2026-11-17)

### Bug Fixes

- match the runner-loss and timeout annotations GitHub writes ([3268002](https://github.com/ExaDev/merge-when/commit/3268002d3865b425856a96a6901c9c10b15822a4))
- read the annotations of every job that did not succeed ([e35ee26](https://github.com/ExaDev/merge-when/commit/e35ee26db8f962920d243f69ccd653cb3329188a))

### Features

- re-run failed jobs lost to a runner, a bounded number of times ([754e30d](https://github.com/ExaDev/merge-when/commit/754e30d98a49398c024d6c0146f1fedfd78c5aa3)), closes [#14](https://github.com/ExaDev/merge-when/issues/14)

## [1.4.0](https://github.com/ExaDev/merge-when/compare/v1.3.0...v1.4.0) (2026-11-15)

### Features

- merge a fast-forward pull request that holds merge commits when allowed ([28ce6af](https://github.com/ExaDev/merge-when/commit/28ce6af829e9df2e4065775dc61b5b5a302ff255))

## [1.3.0](https://github.com/ExaDev/merge-when/compare/v1.2.0...v1.3.0) (2026-10-31)

### Features

- rebase pull requests that have fallen behind their base ([8ac4dd5](https://github.com/ExaDev/merge-when/commit/8ac4dd5b1b36a8726f99c361817c77b0c446f2e9))

## [1.2.0](https://github.com/ExaDev/merge-when/compare/v1.1.1...v1.2.0) (2026-10-30)

### Features

- linearise pull requests with merge commits and refuse to fast-forward them ([f0fec50](https://github.com/ExaDev/merge-when/commit/f0fec505d86f6ff8c8ff7fc207943f0626ccf81f))

## [1.1.1](https://github.com/ExaDev/merge-when/compare/v1.1.0...v1.1.1) (2026-10-29)

## [1.1.0](https://github.com/ExaDev/merge-when/compare/v1.0.1...v1.1.0) (2026-10-10)

### Features

- mark drafts ready for review with then: ready ([6ca75f4](https://github.com/ExaDev/merge-when/commit/6ca75f442261e62903758686e10ca62e6b56c94c))

## [1.0.1](https://github.com/ExaDev/merge-when/compare/v1.0.0...v1.0.1) (2026-10-05)

### Bug Fixes

- leave the first release without a compare link instead of linking to undefined ([d4f0974](https://github.com/ExaDev/merge-when/commit/d4f097453adf40348c999d4a4beabd17e0bb73a7))

## 1.0.0 (2026-10-05)

### Features

- merge pull requests once listed conditions hold ([5a95cb1](https://github.com/ExaDev/merge-when/commit/5a95cb1cd0d417832e7d455ec1187f0d110c97ad))
