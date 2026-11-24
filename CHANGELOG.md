# Changelog

All notable changes to the PrestaFlow CircleCI Orb are documented here.

## [Unreleased]

### Fixed
- **Version from the shop's sources on PrestaShop 8 and 9.** For a Flashlight
  tag without a version, when the image does not set `PS_VERSION`, the
  fallback read `app/AppKernel.php`, which only declares the version itself on
  1.7 (from 8.0 it says `const VERSION = Version::VERSION;`). It now reads
  `src/Core/Version.php` first, then `app/AppKernel.php`. Checked on the
  1.7.8.11, 8.1.7, 8.2.8, 9.0.0 and 9.2.0 images. No change while the images
  set `PS_VERSION`, as all current Flashlight images do.

## [0.2.0] — 2026-11-24

Flashlight fixes of the GitHub Action v2.3.0 to v2.4.1, for
`prestaflow/php-library` 1.9.0.

### Fixed
- **`PRESTAFLOW_PS_VERSION` is taken from the image tag, not set to the tag
  itself.** The library only accepts a bare version, so `latest` (the default)
  or `8.2.8-nginx` stopped the run on `Error with version …`. `8.2.8-nginx`
  now gives `8.2.8`. For a tag without a version (`latest`, `nightly`…), the
  version is read from the image's `PS_VERSION` variable, with
  `app/AppKernel.php` as a fallback; when nothing gives it, it is left to you
  with a warning. The image still uses the tag as given.
- **Flashlight accounts.** The generated `.env.local` sets the image's
  back-office account (`admin@prestashop.com` / `prestashop`) and the demo
  customer (`pub@prestashop.com` / `123456789`) at the lowest priority:
  php-library 1.9.0 no longer falls back on demo accounts.
- **The repository's `.env.local` is merged, not appended to.** The generated
  file is, from the lowest to the highest priority: Flashlight accounts, your
  `.env.local` (or `.env`), the shop's `PRESTAFLOW_FO_URL` /
  `PRESTAFLOW_BO_URL` / `PRESTAFLOW_PS_VERSION`, then the job's `PRESTAFLOW_*`
  variables. `run-tests` removes those keys from composer's environment so the
  library reads them from the file, and the original `.env.local` is put back
  at the end of the job.
- **Readiness.** The `flashlight` command waits for `/admin-dev/` to answer
  302/200 instead of any 2xx/3xx on `/`, and names the last status on timeout.

### Added
- `flashlight_install_module` parameter on `push` and `test`
  (`install_module` on `flashlight`, default `true`): when `composer.json` has
  `type: prestashop-module`, the mounted module is installed with
  `php bin/console prestashop:module install <name>` once the shop is ready.
  A failed install only warns.
- `flashlight-restore` command, run by `push` with `when: always`.
- `PRESTAFLOW_BO_URL` and `PRESTAFLOW_FLASHLIGHT_TAG` in `prestaflow.env`.
- The `flashlight`, `run-tests` and `flashlight-restore` scripts live in
  `src/scripts/` and are inlined by `circleci orb pack` (`<<include(…)>>`).

### Changed
- `flashlight` exports the image tag as `PRESTAFLOW_FLASHLIGHT_TAG` into
  `BASH_ENV` (it exported `PRESTAFLOW_PS_VERSION`, which then reached composer
  and blocked the file's value). `PRESTAFLOW_PS_VERSION` in `prestaflow.env`
  is now the bare version, and is absent when it could not be told.
- A `PRESTAFLOW_*` variable of the job now reaches the tests with Flashlight,
  and wins over the generated values.
- The README references `prestaflow/prestaflow@0.2.0`. It said `@1.0.0`,
  which never matched a release.

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
