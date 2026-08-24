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
  prestaflow: prestaflow/prestaflow@1.0.0
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
  prestaflow: prestaflow/prestaflow@1.0.0

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
  prestaflow: prestaflow/prestaflow@1.0.0

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
| `ps_version` | `"latest"` | Flashlight image tag (`9.0.0`, `8.1.7`, `latest`). |
| `flashlight_mount` | `"auto"` | `auto` \| `root` \| `modules` \| `themes`. Where the workspace is mounted inside PrestaShop. |
| `flashlight_init_scripts` | `""` | Path (absolute or relative to the workspace) to a dir of init scripts, mounted at `/tmp/init-scripts` read-only. |
| `pr_comment` | `""` (auto) | Post/update the PR comment. Auto: `true` when `CIRCLE_PULL_REQUEST` is set, `false` otherwise. |
| `github_token` | `GITHUB_TOKEN` (env var name) | Token used for PR comments on github.com projects. |
| `bitbucket_token` | `BITBUCKET_ACCESS_TOKEN` (env var name) | Token used for PR comments on bitbucket.org projects. |
| `upload_artifacts` | `true` | Store `results.json` + screenshots as CircleCI artifacts. |
| `visual` | `true` | Enable the visual-regression round-trip (download baselines before, upload actual/diff after). |
| `install_deps` | `true` | Install curl/jq/git/bash (and composer if `execute=true`) up-front. Disable to bring your own image. |

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

To share them across jobs, use `persist_to_workspace` on `prestaflow.env` and
`attach_workspace` + `source prestaflow.env` in the downstream job.

---

## Commands

| Command | Purpose |
|---------|---------|
| `prestaflow/push` | Full pipeline: flashlight (opt) → visual-download → run-tests → upload → comment-pr → set-outputs → artifacts. |
| `prestaflow/flashlight` | Boot PrestaShop Flashlight and export `PRESTAFLOW_FO_URL`. |
| `prestaflow/run-tests` | `composer run prestaflow:json:file`. |
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
git tag v0.1.0 && git push --tags
circleci orb publish orb.yml prestaflow/prestaflow@0.1.0
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
