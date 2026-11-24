# PrestaFlow — CircleCI Orb

Run [PrestaFlow](https://prestaflow.io) tests in CircleCI: optionally boot a
PrestaShop instance with [Flashlight](https://github.com/PrestaShop/prestashop-flashlight),
execute your PrestaFlow test suites, upload the report (with error and
visual-regression screenshots), and comment the run summary on the pull request.

This is a straight port of the
[PrestaFlow GitHub Action](https://github.com/PrestaFlow/github-action) and the
[GitLab CI/CD component](https://github.com/PrestaFlow/gitlab-component) — same
inputs, same upload endpoint (`POST /ci/github-action`, provider-agnostic on
the backend), same PR/MR comment format.

---

## Install

```yaml
version: 2.1
orbs:
  prestaflow: prestaflow/prestaflow@0.2.0
```

While iterating, use the dev channel:

```yaml
orbs:
  prestaflow: prestaflow/prestaflow@volatile
```

---

## Quick start (opinionated one-job wrapper)

```yaml
version: 2.1
orbs:
  prestaflow: prestaflow/prestaflow@0.2.0

workflows:
  test:
    jobs:
      - prestaflow/test:
          project_id: pk_01ABCDEFGHIJKLMNOPQR
          flashlight: true
          ps_version: "9.0.0"
          context: prestaflow
```

Provide `PRESTAFLOW_TOKEN` (and optionally `GITHUB_TOKEN` /
`BITBUCKET_ACCESS_TOKEN` for PR comments) as environment variables in the
CircleCI project or an org context.

---

## Compose your own job

```yaml
version: 2.1
orbs:
  prestaflow: prestaflow/prestaflow@0.2.0

jobs:
  test:
    executor: prestaflow/machine
    steps:
      - checkout
      - prestaflow/push:
          project_id: pk_01ABCDEFGHIJKLMNOPQR
          flashlight: true
          ps_version: "9.0.0"
          suites: "BackOffice,FrontOffice"

workflows:
  test:
    jobs:
      - test
```

---

## Executors

| Executor | Base | When to use |
|----------|------|-------------|
| `prestaflow/default` | `cimg/php:8.3` (docker) | Pure test-upload flow. No Flashlight. |
| `prestaflow/machine` | `ubuntu-2404:current` (machine) | **Required when `flashlight: true`** — Docker bind mounts from the checkout are not supported inside `setup_remote_docker`. |

---

## Parameters (on `prestaflow/push`)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `api_url` | `"https://api.prestaflow.io"` | PrestaFlow API base URL. |
| `token` | `PRESTAFLOW_TOKEN` (env var name) | Env var holding the PrestaFlow API token. |
| `project_id` | `""` | PrestaFlow project Product Key (`pk_...`). Optional if the token is scoped. |
| `execute` | `true` | Run `composer run prestaflow:json:file` before upload. |
| `suites` | `""` | Comma-separated suite list (empty = all). |
| `flashlight` | `false` | Start a PrestaShop Flashlight Docker instance. Requires the `machine` executor. |
| `ps_version` | `"latest"` | Flashlight image tag (`9.0.0`, `8.2.8-nginx`, `latest`). See [Flashlight](#flashlight) for the version given to the tests. |
| `flashlight_mount` | `"auto"` | `auto` \| `root` \| `modules` \| `themes`. Where the workspace is mounted inside PrestaShop. |
| `flashlight_init_scripts` | `""` | Path (absolute or relative to the workspace) to a dir of init scripts, mounted at `/tmp/init-scripts` read-only. |
| `flashlight_install_module` | `true` | When `composer.json` has `type: prestashop-module`, install the mounted module in Flashlight once the shop is ready. Set to `false` to skip. |
| `pr_comment` | `""` (auto) | Post/update the PR comment. Auto: `true` when `CIRCLE_PULL_REQUEST` is set, `false` otherwise. |
| `github_token` | `GITHUB_TOKEN` (env var name) | Token used for PR comments on github.com projects. |
| `bitbucket_token` | `BITBUCKET_ACCESS_TOKEN` (env var name) | Token used for PR comments on bitbucket.org projects. |
| `upload_artifacts` | `true` | Store `results.json` + screenshots as CircleCI artifacts. |
| `visual` | `true` | Enable the visual-regression round-trip (download baselines before, upload actual/diff after). |
| `install_deps` | `true` | Install curl/jq/git/bash (and composer if `execute=true`) up-front. Disable to bring your own image. |

---

## Flashlight

With `flashlight: true`, the orb boots `prestashop/prestashop-flashlight:<ps_version>`
and a `mariadb:lts` on the machine executor, waits until `/admin-dev/` answers
(PrestaShop really serving, not just the web server), then prepares the shop
and the settings of your tests.

**PrestaShop version.** `prestaflow/php-library` only accepts a bare version
(`1.7.8.11`, `8.2.8`) in `PRESTAFLOW_PS_VERSION`, and stops on anything else.
The image keeps the tag you give, but the version passed to the tests is read
from it: `8.2.8-nginx` gives `8.2.8`, `1.7.8.11-7.4-fpm-alpine-nginx` gives
`1.7.8.11`. For a tag without a version (`latest`, `nightly`…), the orb reads
the image's `PS_VERSION` variable (`latest` is 9.2.1 at the time of writing).
When nothing gives the version, `PRESTAFLOW_PS_VERSION` is left to you, with a
warning in the step output.

> `latest` is PrestaShop 9.2, which installs the Hummingbird theme. Set
> `PRESTAFLOW_THEME: hummingbird` in the job's `environment:` (or a context),
> or the library looks for Classic's markup.

**Accounts.** Since `prestaflow/php-library` 1.9.0 the library no longer
falls back on demo accounts. With Flashlight, the orb provides the image's
back-office account (`admin@prestashop.com` / `prestashop`) and the demo
customer of the PrestaShop fixtures (`pub@prestashop.com` / `123456789`), at
the lowest priority.

**`.env.local`.** The library reads its settings from `.env.local`, or from
`.env` when there is no `.env.local`. The `flashlight` command writes one
merged `.env.local`, from the lowest to the highest priority:

1. the Flashlight accounts (`PRESTAFLOW_BO_EMAIL`, `PRESTAFLOW_BO_PASSWD`,
   `PRESTAFLOW_FO_EMAIL`, `PRESTAFLOW_FO_PASSWD`);
2. your repository's `.env.local`, or `.env` when there is none, copied as is;
3. the shop: `PRESTAFLOW_FO_URL`, `PRESTAFLOW_BO_URL` (`…/admin-dev/`) and
   `PRESTAFLOW_PS_VERSION`;
4. the `PRESTAFLOW_*` variables of the job (project, context or
   `environment:`; the orb's own settings and tokens excepted).

`run-tests` removes those keys from composer's environment so the library
reads them from the file. A versioned `.env.local` is merged, not overwritten;
`push` runs `flashlight-restore` with `when: always` to put it back (or to
remove the generated file when the repository had none). When you compose
`flashlight` and `run-tests` yourself, end the job with `prestaflow/flashlight-restore`.

**Module.** When `composer.json` has `type: prestashop-module`, the mounted
module is installed with `php bin/console prestashop:module install <name>`
in the container. If an init-script already installed it, PrestaShop upgrades
it instead. A failed install only prints a warning; set
`flashlight_install_module: false` (`install_module: false` on the
`flashlight` command) to skip it.

---

## Required environment variables

| Variable | Required for | Notes |
|----------|--------------|-------|
| `PRESTAFLOW_TOKEN` | Uploading results | Set in project or context. Passed via the `token` param. |
| `GITHUB_TOKEN` | PR comments on github.com | Personal access token with `repo:write`. CircleCI does not inject one automatically — you must create it. |
| `BITBUCKET_ACCESS_TOKEN` | PR comments on bitbucket.org | Repository access token with pull-request write. |

The `comment-pr` step **detects the provider from `CIRCLE_PULL_REQUEST`** and
picks the matching token; if it can't find a token it prints a warning and
skips (never fails the job).

---

## Outputs

The `push` command writes `prestaflow.env` in the job workspace **and**
exports each value into `BASH_ENV`, so any subsequent step in the same job
can consume them as environment variables:

| Variable | Description |
|----------|-------------|
| `PRESTAFLOW_REPORT_ID` | PrestaFlow report ID. |
| `PRESTAFLOW_REPORT_URL` | URL of the report on prestaflow.io. |
| `PRESTAFLOW_PASSED` | Number of passing tests. |
| `PRESTAFLOW_FAILED` | Number of failing tests. |
| `PRESTAFLOW_SKIPPED` | Number of skipped tests. |
| `PRESTAFLOW_TOTAL` | Total number of tests. |
| `PRESTAFLOW_DURATION_MS` | Total execution duration in milliseconds. |
| `PRESTAFLOW_STATUS` | `success` if `failed==0`, else `failure`. |
| `PRESTAFLOW_FO_URL`, `PRESTAFLOW_BO_URL` | Flashlight only: the shop's front and back office (in `prestaflow.env`; `PRESTAFLOW_FO_URL` is also exported into `BASH_ENV`). |
| `PRESTAFLOW_PS_VERSION` | Flashlight only: the PrestaShop version given to the tests, when it could be told (in `prestaflow.env`). |
| `PRESTAFLOW_FLASHLIGHT_TAG` | Flashlight only: the image tag (`ps_version`). |

To share them across jobs, use `persist_to_workspace` on `prestaflow.env` and
`attach_workspace` + `source prestaflow.env` in the downstream job.

---

## Commands

| Command | Purpose |
|---------|---------|
| `prestaflow/push` | Full pipeline: flashlight (opt) → visual-download → run-tests → upload → comment-pr → flashlight-restore (opt) → set-outputs → artifacts. |
| `prestaflow/flashlight` | Boot PrestaShop Flashlight, install the mounted module, write the merged `.env.local` and export `PRESTAFLOW_FO_URL`. |
| `prestaflow/flashlight-restore` | Put the repository's `.env.local` back after `flashlight` (`when: always`). |
| `prestaflow/run-tests` | `composer run prestaflow:json:file`, without the `PRESTAFLOW_*` keys written to `.env.local` in its environment. |
| `prestaflow/visual-download` | Fetch baseline manifest for the branch, download PNGs. |
| `prestaflow/visual-upload` | No-op (visual PNGs travel with `upload`); kept for symmetry. |
| `prestaflow/upload` | POST `results.json` + screenshots to the API. Sets `PRESTAFLOW_REPORT_*`. |
| `prestaflow/comment-pr` | Post/update the PR summary comment. Provider-detected. |
| `prestaflow/set-outputs` | Parse `results.json`, export counters, exit non-zero on failures. |
| `prestaflow/install-deps` | Install curl/jq/git/bash (and optionally composer). |

---

## Publishing (maintainer notes)

```bash
# Pack and lint locally
circleci orb pack src/ > orb.yml
circleci orb validate orb.yml

# First-time dev publish (requires namespace + token)
circleci orb publish orb.yml prestaflow/prestaflow@dev:first

# Promote to production on a tag
git tag v0.2.0 && git push --tags
circleci orb publish orb.yml prestaflow/prestaflow@0.2.0
```

CI (`.circleci/config.yml`) uses `circleci/orb-tools` to lint, pack, review,
and publish. Production releases fire on `v*.*.*` tags via the
`orb-publishing` context.

---

## Behavior differences vs the GitHub Action

The port is behavior-for-behavior with a few platform-imposed changes:

1. **PR-comment auth.** The GitHub Action uses the auto-injected `GITHUB_TOKEN`.
   CircleCI does not inject one, so you must provide `GITHUB_TOKEN` (github.com)
   or `BITBUCKET_ACCESS_TOKEN` (bitbucket.org) as a project or context variable.
2. **Executor for Flashlight.** The GitHub Action uses `docker` service actions;
   the GitLab component uses `docker:dind`. CircleCI's `setup_remote_docker`
   forbids bind mounts from the job workspace, so `flashlight: true` requires
   the `machine` executor.
3. **Outputs.** The Action sets step outputs via `core.setOutput`. CircleCI has
   no such API, so outputs are exported via `BASH_ENV` for the current job and
   written to `prestaflow.env` for `persist_to_workspace` handoff.
4. **PR detection.** The Action uses `github.event.pull_request`. CircleCI
   exposes `CIRCLE_PULL_REQUEST` (a URL). The orb parses the URL for the PR
   number and the provider host.

Everything else — inputs, Flashlight boot, visual round-trip, results upload,
comment marker format (`<!-- prestaflow-run:<projectKey> -->`) — matches.

---

## License

MIT — see [LICENSE](LICENSE).
