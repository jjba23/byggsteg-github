# Vision

Byggsteg-github is the piece that lets a GitHub repository run a Byggsteg job, and
it exists because GitHub has no `PLUGIN_*` convention: a workflow hands an action its
`inputs`, and something has to turn those into the Lisp job code Byggsteg speaks and
then follow the run to a green or a red build. Everything here is deliberately thin —
one shell script, one action, one reusable workflow — and this document is about
keeping it thin while making it complete enough that nobody has to write the same
glue again.

## Where byggsteg-github is today

The whole bridge is `src/bash/byggsteg-github.bash` (659 lines), driven from two
doors that take the same request: the composite action in `action.yml`, whose inputs
become the environment the script reads, and the reusable workflow in
`.github/workflows/byggsteg.yml`, which runs the three steps in their own job steps so
a red build points at the thing that failed.

What exists, concretely:

- **Three steps and `all`.** `get-token`, `submit-job` and `poll-job` share a token
  and a log id through files under a directory in `$RUNNER_TEMP`; `all` runs the three
  inside one step, which is the default because most workflows want a pipeline and not
  plumbing.
- **The job code is written here, not carried in YAML.** `tasks: maak-test maak-deploy`
  becomes a thunk naming `project`, `branch-name` and `clone-url`, and a field whose
  value is unknown is left out rather than sent empty — because a thunk that names no
  branch asks the deployment for the project's default, which is what a person writing
  one by hand would have relied on.
- **Three answers come from the GitHub context.** The project name comes from
  `GITHUB_REPOSITORY`, the branch from `GITHUB_HEAD_REF` for a pull request and
  `GITHUB_REF_NAME` otherwise, and the clone URL from `GITHUB_SERVER_URL` and
  `GITHUB_REPOSITORY`. A repository whose Byggsteg project is named differently, or
  that clones over SSH, names them and the context stops being asked.
- **`%%NAME%%` placeholders are resolved, never evaluated.** Every `GITHUB_*`
  variable is available to a job code, along with `BYGGSTEG_PROJECT`,
  `BYGGSTEG_BRANCH` and `BYGGSTEG_CLONE_URL`, and a value is substituted as text
  rather than run through a shell — which is what makes one job code portable between
  two CI systems.
- **Values that would break the Lisp are refused before anything is sent.** A task
  name carrying a quote, a backslash or a newline ends the string early and turns a job
  definition into a syntax error somewhere the reader cannot see, so it is rejected
  with the setting named.
- **Secrets travel in the environment and nowhere else.** Nothing is built into a
  command line, so a CI log or `ps` shows a name and not a value; each step is handed
  only the settings it needs, so the password is not in a container that is only
  following a log; and the shared workflow asks for `contents: read` and nothing more.
- **Two runtimes, one truth.** `auto` prefers docker and falls back to podman, `script`
  runs the bridge with no container at all, and the workspace is mounted and owned by
  the runner — a numeric `--user` for a docker daemon that runs as root,
  `--userns=keep-id` for rootless podman, which is the reason that branch exists.
- **The wiring is tested as a fact.** The suite reads `action.yml` and the workflow as
  files and compares them with each other and with what the script reads, so an input
  that is declared and never handed over fails a test rather than a caller's pipeline;
  a stand-in bridge records every setting it was handed, and a mock deployment answers
  the end-to-end runs.

Two decisions constrain what comes next. The first is that **the bridge is a shim**: it
does not run the pipeline, own the queue or interpret the log, it hands a job to a
deployment and reports what that deployment said. The second is that **the script is the
contract**, and the action and the workflow are two spellings of the same inputs, which
is why they are tested against each other rather than separately.

The one known limit is stated in the README: this is not for GitHub Enterprise Server,
because checking out the bridge at the called workflow's commit uses `job.workflow_sha`
and `job.workflow_repository`, which are unavailable there.

## The vision

1. **The bridge has a specification.** The settings, the job code it writes and its
   exit codes are documented as a contract and covered in both directions, so a
   repository pinned to a tag can upgrade without reading a diff to find out whether a
   field changed meaning.

2. **A pinned tag runs pinned code, anywhere.** The workflow checks out the bridge at
   the commit the caller pinned, and names that commit explicitly on a server where
   `job.workflow_sha` does not exist, so GitHub Enterprise Server is a parameter rather
   than a missing feature.

3. **A failure is attributable.** A red build names which of the three steps failed
   and repeats the deployment's own sentence — the `{"error": "..."}` Byggsteg sends —
   rather than a status number or the retry noise that preceded it.

4. **The bridge reports back in GitHub's own vocabulary.** Annotations on the lines a
   failure came from, a step summary with the run's stages and durations, and outputs a
   later step can consume, so a reviewer sees the verdict where the code is.

5. **Every event that can start a build is resolved correctly.** A pull request from a
   fork, a merge-queue ref, a tag and a `push` each resolve to the right branch, clone URL
   and commit, and each has a test on the resolution table rather than a comment saying it
   was thought about.

## Features that are in scope and not built yet

- **GitHub Enterprise Server.** The README names the reason precisely: `workflow_sha`
  and `workflow_repository` are unavailable there. The hard part is a bootstrap paradox —
  the input naming the bridge commit has to be read by a workflow that has already had to
  check something out — so the fix is a documented input with a safe default.
- **More of the run as an output.** The action exposes `log-id` and nothing else, so a
  step that wants the run id, the status or the tarballs has to call the API itself. The
  hard part is that `poll-job` knows all of it and writes only files into the workspace;
  exposing them means deciding which of them are a promise.
- **Merge queues and `pull_request_target`.** A merge-queue ref is not a branch name,
  and the question a repository is really asking is "build the merge result, not the
  head". The hard part is that the answer differs per event and getting it wrong silently
  builds the wrong commit — the one class of bug this project cannot afford.
- **Artifacts.** A Byggsteg run collects tarballs and the workflow collects its own. The
  hard part is deciding whether they are one thing: downloading maps a deployment's
  artifact ids into the runner, and re-uploading duplicates them under a second retention
  policy.
- **A matrix that maps to Byggsteg's matrix.** GitHub's `strategy.matrix` and Byggsteg's
  `matrix` field are the same idea in two spellings. The hard part is that GitHub's run in
  parallel and Byggsteg's run in order inside one log, so a faithful mapping changes what
  a reader sees.

## New features that would be worth having

- **`::error` and `::warning` annotations.** The deployment already collects warnings
  and errors from every step into one diagnostics panel; turning each into a workflow
  command would put a failure in the diff, at the file and line the compiler named.
  This is the highest-value idea in this document and the cheapest.
- **A step summary.** `$GITHUB_STEP_SUMMARY` accepts Markdown, and the API already
  answers with the run's stages, their durations and its artifacts. A summary page that
  says "build 42s, test 1m 30s, deploy 8s, two tarballs" is a few dozen lines of shell.
- **The job from a file in the repository.** A `byggsteg.job` that the bridge sends
  when `tasks` is absent would let a pipeline be reviewed in the repository it belongs
  to, with history and blame, instead of living in a workflow input.
- **An OIDC-based sign-in** (speculative, and it needs a change on the Byggsteg side):
  GitHub can mint a short-lived OIDC token naming the repository and the workflow, which
  would replace a shared email and password with a trust relationship. It is out of
  scope here only because the deployment has to be able to verify the token.

## Contributions that would move the needle

1. **Annotations from the deployment's diagnostics.** Small, self-contained, and it
   changes how a failure feels: one `::error file=…,line=…` per warning the run printed,
   emitted while following the log.
2. **The step summary.** Same shape of work, same audience, and it uses only what
   `poll-job` already holds.
3. **More action outputs.** A `run-id`, a `status` and an `artifacts` list turn the
   action into something a later step can build on, and the values are already in the
   files the script writes.
4. **Enterprise Server support**, with the resolution table under test. Unglamorous,
   and it is the difference between a bridge for github.com and a bridge for GitHub.
5. **Event resolution tests.** A table of event, ref and expected project/branch/clone
   URL, checked without a runner, is the cheapest insurance against building the wrong
   commit.
6. **The job-from-a-file feature**, once the precedence rules with `tasks` and
   `job-code` are written down.
7. **Artifact download**, which is the one item here that needs decisions on the
   Byggsteg side as well.

## Compared to related projects

| Project | What it is | Where byggsteg-github differs |
| --- | --- | --- |
| byggsteg-woodpecker (this project's sibling) | The same bridge for Woodpecker, in a 16.6 MB Alpine image, driven by `settings` that Woodpecker turns into `PLUGIN_*` variables | The same three steps and the same image, driven from GitHub's inputs and reusable workflows; the two share the image, not the script |
| `nektos/act` | Runs GitHub workflows locally by emulating the runner and its Docker plumbing | act emulates GitHub so a workflow can run elsewhere; this does the opposite — GitHub runs, and the work goes to a CI you own. Nothing is emulated |
| The `actions/*` family | Container and JavaScript actions that run work on the runner | Those run the work; this hands the work to a deployment, and its job is to describe it and read the answer |
| Buildkite and Cirrus CI agents | An agent that claims work from a hosted control plane and reports back through the forge | A control plane you do not own; here the control plane is a Byggsteg deployment, and the pipeline is Lisp you can read |
| Jenkins' GitHub plugin, and GitLab's mirroring | A forge that triggers an external CI and shows its status | Those trigger and mirror a status; this passes a pipeline as data and reports the deployment's own log, exit and diagnostics |
| `gh workflow run` and `repository_dispatch` | The built-in way to fire a workflow from outside | The same direction, but the polling, the log and the verdict are left to a script somebody writes by hand |

What the others do that byggsteg-github could still add is mostly GitHub's own
vocabulary — annotations, step summaries, outputs — which is why the top three
contributions are exactly those. Buildkite and Cirrus show what an agent that owns its
queue looks like, and act shows the value of running a pipeline without the forge;
neither is worth copying here.

Where this project is ahead and should stay ahead: no control plane to onboard, no
marketplace action to trust, no second dialect — a repository that can write two lines
of YAML has a pipeline. Secrets never touch a command line, the image is a few
megabytes of bash and curl, and the wiring between the action, the workflow and the
script is tested rather than assumed. That is what makes it safe to pin, which is the
basis on which somebody adopts it.

## In the long run

The first bet is that **the bridge stays a shim**. Every item above reports or describes
the deployment's answer; none runs, schedules or interprets a pipeline. The moment this
project knows how a build works, it is a second Byggsteg to keep in step.

The second is **one implementation with several drivers**. Woodpecker's bridge and this
one already share the image, the three steps and the file protocol between them. If the
two scripts converge into one with a thin driver per CI, a third CI becomes an afternoon
rather than a rewrite, and artifacts, annotations and summaries get written once.

The third is **trust instead of a password**. A repository handing a shared credential
to a deployment is the weakest part of the current shape, and anything that lets a
deployment verify *which* repository and workflow is asking would remove it.

## What would make this document wrong

If GitHub ever ships a first-class way to delegate a job to an external CI with a log and
a status, the bridge becomes a compatibility layer rather than a product, and the honest
move is to say so. If Byggsteg grows its own forge integration, this project has no reason
to exist. Neither is likely soon, and both are cheaper to notice from inside a project that
stayed small.

*A vision describes intent, not commitments: nothing here is promised for a release.*
