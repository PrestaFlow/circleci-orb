# Changelog

All notable changes to the PrestaFlow CircleCI Orb are documented here.

## [0.1.0] — 2026-08-24

Initial release. Ports the
[PrestaFlow GitHub Action](https://github.com/PrestaFlow/github-action) and the
[GitLab CI/CD component](https://github.com/PrestaFlow/gitlab-component)
to a CircleCI Orb (`prestaflow/prestaflow`).

### Added
- Executors: `default` (`cimg/php:8.3` docker) and `machine` (`ubuntu-2404:current`).
- Commands: `push`, `flashlight`, `run-tests`, `visual-download`, `visual-upload`,
  `upload`, `comment-pr`, `set-outputs`, `install-deps`.
- Job: `test` — opinionated one-shot wrapper (`checkout` + `push`).
- Provider-agnostic PR comment via git-remote sniffing (github.com, bitbucket.org).
- `prestaflow.env` output file + `BASH_ENV` exports for downstream steps.
- `.circleci/config.yml` running `orb-tools/{lint,pack,review,publish}`.
- `tests/smoke.yml` — offline integration harness against a python HTTP stub.
