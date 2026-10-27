#!/usr/bin/env bash

# byggsteg-github

# SPDX-License-Identifier: MIT
# Copyright © 2026 Josep Bigorra <jjbigorra@gmail.com>

# The licence's own text -- the permission notice and the disclaimer -- is in
# LICENSE, which travels with every copy of this software.

# The bridge from a GitHub Actions job to a Byggsteg deployment: the same
# image byggsteg-woodpecker runs, driven from a GitHub workflow.
#
#   byggsteg-github get-token    sign in, and keep the token
#   byggsteg-github submit-job   hand Byggsteg a job, keep its log id
#   byggsteg-github poll-job     follow that log, and pass or fail the job
#   byggsteg-github all          the three, in that order, in one step
#   byggsteg-github help         the settings this script reads
#
# Woodpecker turns each `settings' key of a step into a PLUGIN_-prefixed
# environment variable for that step's image.  GitHub has no such convention:
# there a workflow passes an action its `inputs', and a shell script reads the
# environment.  So this script is what stands in Woodpecker's place.  It reads
# the settings a GitHub workflow (or a person at a terminal) can write, works
# out the rest from the GitHub context, hands the image the same PLUGIN_*
# variables Woodpecker would have handed it, and runs one step of the bridge.
#
# Two things are worth knowing before reading it:
#
#   * the job code may be left out.  Give TASKS -- and, when the deployment
#     needs one, a daemon name -- and the thunk is written here, which is what
#     the common workflow wants: it says what to run rather than writing Lisp
#     inside YAML.  Give JOB_CODE instead and it is sent as written, in which
#     case its %%NAME%% placeholders are resolved by the bridge from the
#     container's environment: the GITHUB_* variables are there, and so are
#     BYGGSTEG_PROJECT, BYGGSTEG_BRANCH and BYGGSTEG_CLONE_URL -- this
#     script's own answers to the three questions GitHub answers differently
#     (GitHub says owner/repo where a Byggsteg job wants a project name);
#   * `script' is a runtime of its own.  A machine that has the bridge script
#     and no container runtime can run it directly, which is also what the
#     test suite does for the checks that need no image.
#
# The one rule the whole script follows is that a failure is read by somebody
# who is not at a terminal: every refusal says which setting it is about, what
# was refused, and what to do about it.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# The image the steps run in, and the deployment they are aimed at, when a
# workflow names neither.  The image is byggsteg-woodpecker's: one bridge, one
# script, and the platform is only the way it is driven.
readonly DEFAULT_IMAGE='docker.io/jjba23/byggsteg-woodpecker:v0.3.0'
readonly DEFAULT_URL='https://byggsteg.jointhefreeworld.org'

# The files the steps exchange.  Woodpecker runs every step of a pipeline in
# one working directory, which is how its three steps talk to each other;
# GitHub gives every step of a job the same machine and the same workspace, so
# the same trick works here.  The names are byggsteg-woodpecker's, because the
# script that reads and writes them is its script.
readonly TOKEN_FILE='x-bewaking-byggsteg'
readonly LOG_ID_FILE='byggsteg-log-id'

# Where that working directory is mounted inside the container.  Only the
# mount point is fixed: which host directory it is a mount of is the
# workspace, and a workflow may name it.
readonly CONTAINER_WORKSPACE='/byggsteg/workspace'

# The workspace, the runtime and the resolved addresses are filled in by
# `resolve_*' below, before any step is attempted; naming them here keeps the
# `-u' at the top of the file honest about what this script keeps around.
workspace=''
runtime=''
bridge_script=''
container_command=()

# The names handed to the container besides the bridge's own settings.  They
# are passed by name rather than by value, so a secret never appears in the
# container's command line -- where a CI log, or `ps' on the runner, would
# show it to anybody looking.
readonly -a PASSED_NAMES=(
  # The GitHub context, so that a job code given as JOB_CODE may name it:
  # %%GITHUB_REPOSITORY%%, %%GITHUB_REF_NAME%%, %%GITHUB_SHA%% and the rest
  # resolve to what they are worth in the workflow that called this step.
  GITHUB_ACTOR
  GITHUB_API_URL
  GITHUB_BASE_REF
  GITHUB_EVENT_NAME
  GITHUB_HEAD_REF
  GITHUB_JOB
  GITHUB_REF
  GITHUB_REF_NAME
  GITHUB_REF_TYPE
  GITHUB_REPOSITORY
  GITHUB_REPOSITORY_OWNER
  GITHUB_RUN_ATTEMPT
  GITHUB_RUN_ID
  GITHUB_RUN_NUMBER
  GITHUB_SERVER_URL
  GITHUB_SHA
  GITHUB_WORKFLOW
  # This script's own answers, which a job code may name too.
  BYGGSTEG_PROJECT
  BYGGSTEG_BRANCH
  BYGGSTEG_CLONE_URL
  # The bridge's own tuning, for a build that needs a slower deployment, a
  # longer request or an explanation of what it sent.
  BYGGSTEG_DEBUG
  BYGGSTEG_RETRY_ATTEMPTS
  BYGGSTEG_RETRY_INTERVAL
  BYGGSTEG_CONNECT_TIMEOUT
  BYGGSTEG_REQUEST_TIMEOUT
)

# ---------------------------------------------------------------------------
# Logging
#
# The bridge logs one line per thing it does, with a level and a UTC time, so
# that a CI log can be searched for the lines that matter.  This script logs
# the same way, and for the same reason: what it says and what the bridge says
# should read as one log.  Colours are plain ANSI escapes rather than `tput',
# so nothing here depends on a terminfo database.
# ---------------------------------------------------------------------------

_style_info=$'\033[1m'     # bold
_style_warn=$'\033[1;33m'  # bold yellow
_style_error=$'\033[1;31m' # bold red
_style_debug=$'\033[0;36m' # cyan
_style_reset=$'\033[0m'

# timestamp -- now, in UTC, the way every line of both logs says it.
timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# emit_log <style> <level> <stream> <message...>
emit_log() {
  local -r style="$1" level="$2" stream="$3"
  shift 3
  printf '%s[%s][%s] %s%s\n' "${style}" "${level}" "$(timestamp)" "$*" "${_style_reset}" >&"${stream}"
}

log_debug() {
  case "${BYGGSTEG_DEBUG:-}" in
    '' | 0 | false | no | off) return 0 ;;
  esac
  emit_log "${_style_debug}" 'DEBUG' 1 "$@"
}

log_info() {
  emit_log "${_style_info}" 'INFO' 1 "$@"
}

log_error() {
  emit_log "${_style_error}" 'ERROR' 2 "$@"
}

error_exit() {
  log_error "$*"
  exit 1
}

# A failure nobody planned for -- an unset variable, a write that did not
# happen -- would otherwise fail the step with no explanation but bash's own
# one-liner.  This says where it happened and what was being run.
_on_unexpected_failure() {
  local -r status="$1" line="$2" command="$3"
  log_error "Unexpected failure (exit ${status}) at line ${line}: ${command}"
}
trap '_on_unexpected_failure "$?" "${LINENO}" "${BASH_COMMAND}"' ERR

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

# setting <name> -- what the environment holds for NAME, or nothing.  Reading
# a setting that was never set is the normal case here: most of them have an
# answer derived from the GitHub context instead.
setting() {
  printf '%s' "${!1:-}"
}

# require_setting <name> <what it is for>
require_setting() {
  local -r name="$1" what="$2"
  if [[ -z "$(setting "${name}")" ]]; then
    error_exit "${name} is required ${what}"
  fi
}

# require_one_of <what it is for> <names...> -- at least one of NAMES has to
# hold something: a job is asked for either as tasks or as a whole job code,
# and never as neither.
require_one_of() {
  local -r what="$1"
  shift
  local name
  for name in "$@"; do
    [[ -n "$(setting "${name}")" ]] && return 0
  done
  error_exit "one of $* is required ${what}"
}

# require_file <file> <what to do about it> -- a file an earlier step should
# have left behind, and that should hold something.  Checked here rather than
# left to the bridge, so a step that cannot work says so before an image is
# pulled and a container started.
require_file() {
  local -r file="$1" hint="$2"
  [[ -r "${file}" ]] || error_exit "missing ${file} (${hint})"
  [[ -s "${file}" ]] || error_exit "empty ${file} (${hint})"
}

# assert_lisp_writable <value> <setting> -- refuse a value that cannot be
# written into a job code.  A task name with a quote in it would end the Lisp
# string early and turn a job definition into a syntax error somewhere the
# reader cannot see, so it is refused here, where the setting that carried it
# can be named.
#
# The check is its own function, called directly rather than from inside a
# substitution, because a refusal written as `listed+="$(...)"' would only end
# that substitution: bash keeps going, composes the rest of the code without
# the value that was refused, and the step ends up green on a job that runs
# nothing.  So the whole value is checked before any of it is written.
assert_lisp_writable() {
  local -r value="$1" name="$2"
  if [[ ${value} == *'"'* || ${value} == *\\* || ${value} == *$'\n'* ]]; then
    error_exit "${name} cannot be written into a job code (no quotes, backslashes or newlines are allowed): ${value}"
  fi
}

# lisp_string <value> -- VALUE as the Lisp string a job code may hold.  The
# value is expected to have been checked by `assert_lisp_writable' first, so
# this one cannot fail and may be used where a string is wanted.
lisp_string() {
  printf '"%s"' "$1"
}

# ---------------------------------------------------------------------------
# What the settings resolve to
#
# Three questions have an answer in the GitHub context and a different one in
# a Byggsteg job: which project the run belongs to, which branch it is about,
# and where the source is cloned from.  GitHub says owner/repo and gives the
# branch only as a ref name; a job wants a project name and a clone address.
# An input says it outright when a repository's answer is not the one wanted
# (a job named after the repository rather than after the directory, a clone
# over SSH rather than HTTPS), and the GitHub context answers it otherwise.
# ---------------------------------------------------------------------------

# resolve_addresses -- fill in the project, the branch and the clone address.
resolve_addresses() {
  local repository="${GITHUB_REPOSITORY:-}"

  project="$(setting BYGGSTEG_PROJECT)"
  if [[ -z "${project}" && -n "${repository}" ]]; then
    project="${repository##*/}"
  fi

  branch="$(setting BYGGSTEG_BRANCH)"
  if [[ -z "${branch}" ]]; then
    # A run about a pull request is about the branch it came from, which is
    # what GITHUB_HEAD_REF names; every other run is about the ref it is on.
    branch="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-}}"
  fi

  clone_url="$(setting BYGGSTEG_CLONE_URL)"
  if [[ -z "${clone_url}" && -n "${repository}" ]]; then
    clone_url="${GITHUB_SERVER_URL:-https://github.com}/${repository}.git"
  fi

  # The three are exported under their own names as well as read here: a job
  # code may name them as %%BYGGSTEG_PROJECT%% and the like, and the bridge
  # resolves a placeholder from the environment it finds in the container.
  export BYGGSTEG_PROJECT="${project}"
  export BYGGSTEG_BRANCH="${branch}"
  export BYGGSTEG_CLONE_URL="${clone_url}"
}

# resolve_workspace -- the directory the three steps share.  A job's steps run
# on one machine, so a directory under the runner's own temporary directory is
# enough, is nobody's checkout, and is cleaned up with the runner.  It is
# printed, because a build that failed is easier to read when the answer it
# came from can be looked at.
resolve_workspace() {
  local -r asked="$(setting BYGGSTEG_WORKSPACE)"
  if [[ -n "${asked}" ]]; then
    workspace="${asked}"
  else
    workspace="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/byggsteg"
  fi
  mkdir -p "${workspace}"
  log_debug "Workspace: ${workspace}"
}

# resolve_runtime -- the container runtime the steps are run with, and the
# checks that make a named one usable before a step is attempted.  `auto' is
# the default and prefers docker: it is what a GitHub-hosted runner has, and
# what the platform itself runs its own steps in.
resolve_runtime() {
  local asked
  asked="$(setting BYGGSTEG_RUNTIME)"
  asked="${asked:-auto}"

  case "${asked}" in
    docker | podman)
      if ! command -v "${asked}" >/dev/null 2>&1; then
        error_exit "BYGGSTEG_RUNTIME is ${asked}, and there is no ${asked} on this machine"
      fi
      runtime="${asked}"
      ;;
    script)
      require_setting BYGGSTEG_BRIDGE_SCRIPT 'when BYGGSTEG_RUNTIME is script'
      if [[ ! -r "${BYGGSTEG_BRIDGE_SCRIPT}" ]]; then
        error_exit "BYGGSTEG_BRIDGE_SCRIPT is not a file this machine can read: ${BYGGSTEG_BRIDGE_SCRIPT}"
      fi
      # Read as an absolute path now, while the caller's directory is still
      # the one a relative path would be relative to: the steps run from the
      # workspace, which is a different place entirely.
      local directory
      directory="$(cd -- "$(dirname -- "${BYGGSTEG_BRIDGE_SCRIPT}")" && pwd)"
      bridge_script="${directory}/$(basename -- "${BYGGSTEG_BRIDGE_SCRIPT}")"
      runtime='script'
      ;;
    auto)
      if command -v docker >/dev/null 2>&1; then
        runtime='docker'
      elif command -v podman >/dev/null 2>&1; then
        runtime='podman'
      else
        error_exit 'no container runtime found: install docker or podman, or set BYGGSTEG_RUNTIME=script and point BYGGSTEG_BRIDGE_SCRIPT at byggsteg-woodpecker.bash'
      fi
      ;;
    *)
      error_exit "BYGGSTEG_RUNTIME must be auto, docker, podman or script, not '${asked}'"
      ;;
  esac

  log_debug "Runtime: ${runtime}"
}

# ---------------------------------------------------------------------------
# The job code
# ---------------------------------------------------------------------------

# compose_job_code -- write the job thunk, from TASKS and the addresses, into
# `job_code'.
#
# The shape is the one every example in byggsteg-woodpecker uses, because it
# is the shape a Byggsteg deployment parses; writing it here is what lets a
# workflow say `tasks: maak-test maak-deploy' instead of carrying Lisp.
#
# A field whose value is not known is left out rather than sent empty: a thunk
# that names no branch asks for the project's own default, which is what a
# person writing one by hand would have relied on.
#
# It fills in that variable rather than printing the thunk, and that is
# deliberate: a refusal raised inside a command substitution would end the
# substitution and leave the script running with a job code missing whatever
# was refused -- a green step for a job that runs nothing.  Run in this shell,
# every refusal below ends the step, and `job_code' is only written once the
# whole thunk is known to be writable.
compose_job_code() {
  local -r tasks="$(setting BYGGSTEG_TASKS)"
  local -r daemon="$(setting BYGGSTEG_DAEMON_NAME)"

  local -a task_names=()
  read -r -a task_names <<<"${tasks}"

  if [[ ${#task_names[@]} -eq 0 ]]; then
    error_exit 'BYGGSTEG_TASKS is required when no BYGGSTEG_JOB_CODE is given'
  fi
  if [[ -z "${project}" ]]; then
    error_exit 'no project to submit the job for: set BYGGSTEG_PROJECT, or run this where GITHUB_REPOSITORY names the repository'
  fi

  local listed='' task
  for task in "${task_names[@]}"; do
    assert_lisp_writable "${task}" BYGGSTEG_TASKS
    listed+="$(lisp_string "${task}") "
  done
  listed="${listed% }"

  assert_lisp_writable "${project}" BYGGSTEG_PROJECT
  [[ -n "${daemon}" ]] && assert_lisp_writable "${daemon}" BYGGSTEG_DAEMON_NAME
  [[ -n "${branch}" ]] && assert_lisp_writable "${branch}" BYGGSTEG_BRANCH
  [[ -n "${clone_url}" ]] && assert_lisp_writable "${clone_url}" BYGGSTEG_CLONE_URL

  local code
  code=$(printf '(lambda()\n  `((task . (%s))' "${listed}")
  if [[ -n "${daemon}" ]]; then
    code+=$(printf '\n    (daemon-name . %s)' "$(lisp_string "${daemon}")")
  fi
  code+=$(printf '\n    (project . %s)' "$(lisp_string "${project}")")
  if [[ -n "${branch}" ]]; then
    code+=$(printf '\n    (branch-name . %s)' "$(lisp_string "${branch}")")
  fi
  if [[ -n "${clone_url}" ]]; then
    code+=$(printf '\n    (clone-url . %s)' "$(lisp_string "${clone_url}")")
  fi
  job_code="${code}))"
}

# ---------------------------------------------------------------------------
# Handing the settings to the bridge
#
# The bridge reads PLUGIN_BYGGSTEG_* and PLUGIN_POLL_* -- the names Woodpecker
# makes out of a step's settings -- so the settings are turned into exactly
# those, in this process's environment.  They are exported rather than built
# into an argument list because that is what makes the secret safe: a
# container is then handed the *name* of the variable and reads its value from
# this process, so the password is never part of a command line.
#
# Each step exports the settings it needs and no others: the sign-in password
# has no business in a container that is only following a log.
# ---------------------------------------------------------------------------

export_plugin_common() {
  export PLUGIN_BYGGSTEG_URL="${url}"
}

export_plugin_get_token() {
  export_plugin_common
  export PLUGIN_BYGGSTEG_EMAIL="${email}"
  export PLUGIN_BYGGSTEG_PASSWORD="${password}"
}

export_plugin_submit_job() {
  export_plugin_common
  export PLUGIN_BYGGSTEG_JOB_CODE="${job_code}"
}

export_plugin_poll_job() {
  export_plugin_common
  # The bridge reads each of these only when it is set, so an unset one keeps
  # its own default (a limit of 4096 polls, eight seconds apart, rendered).
  local name value
  for name in BYGGSTEG_POLL_LIMIT BYGGSTEG_POLL_INTERVAL_SECONDS BYGGSTEG_POLL_VIEW; do
    value="$(setting "${name}")"
    [[ -n "${value}" ]] || continue
    export "PLUGIN_${name#BYGGSTEG_}=${value}"
  done
}

# ---------------------------------------------------------------------------
# Running the bridge
# ---------------------------------------------------------------------------

# build_container_command <step> -- fill container_command with what the
# runtime is called with.
#
# The workspace is mounted, because the steps talk through files; the
# container runs as the user that owns it, so nothing is left behind that the
# steps after it cannot read or remove; and every setting the step needs -- and
# every name a job code may mention -- is passed by name.
build_container_command() {
  local -r step="$1"

  container_command=(
    run --rm
    --volume "${workspace}:${CONTAINER_WORKSPACE}"
    --workdir "${CONTAINER_WORKSPACE}"
  )

  # Who the steps run as, which is not the same question for both runtimes.  A
  # docker daemon runs as root and takes a numeric user as it is given.  A
  # rootless podman cannot: a numeric uid is mapped into its subordinate range,
  # where it owns nothing, and the step would then be unable to write the token
  # and log files into the workspace it was handed -- so `keep-id' is asked for
  # instead, which puts the same user inside the container as outside it.  Root
  # podman is a daemon like docker's and takes the number.
  if [[ "${runtime}" == 'podman' && "$(id -u)" != '0' ]]; then
    container_command+=(--userns=keep-id)
  else
    container_command+=(--user "$(id -u):$(id -g)")
  fi

  local name
  for name in "${PASSED_NAMES[@]}"; do
    [[ -n "${!name:-}" ]] && container_command+=(-e "${name}")
  done

  # The plugin settings are built by the step functions above, so they are
  # collected the same way rather than listed a second time: whatever this
  # process is holding under the bridge's own prefix is handed on.
  local plugin
  for plugin in ${!PLUGIN_@}; do
    container_command+=(-e "${plugin}")
  done

  container_command+=("${image}" "${step}")
  log_debug "Running: ${runtime} ${container_command[*]}"
}

# run_bridge <step> -- run one step of the bridge, where the settings say.
run_bridge() {
  local -r step="$1"

  case "${runtime}" in
    docker | podman)
      build_container_command "${step}"
      (cd "${workspace}" && "${runtime}" "${container_command[@]}")
      ;;
    script)
      log_debug "Running: ${bridge_script} ${step}"
      (cd "${workspace}" && bash "${bridge_script}" "${step}")
      ;;
  esac
}

# ---------------------------------------------------------------------------
# The steps
# ---------------------------------------------------------------------------

get_token() {
  require_setting BYGGSTEG_EMAIL 'to sign in to Byggsteg'
  require_setting BYGGSTEG_PASSWORD 'to sign in to Byggsteg'

  export_plugin_get_token
  run_bridge get-token
}

submit_job() {
  require_one_of 'to submit a job' BYGGSTEG_TASKS BYGGSTEG_JOB_CODE
  require_file "${workspace}/${TOKEN_FILE}" 'run the get-token step first'

  job_code="$(setting BYGGSTEG_JOB_CODE)"
  if [[ -z "${job_code}" ]]; then
    compose_job_code
  fi

  export_plugin_submit_job
  run_bridge submit-job

  # The queued run's log id is handed to the workflow, so a step after this
  # one can name the run it started -- to link it, or to comment it on a pull
  # request.  Outside GitHub there is nowhere to hand it, and that is fine.
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    if [[ -r "${workspace}/${LOG_ID_FILE}" ]]; then
      printf 'log-id=%s\n' "$(<"${workspace}/${LOG_ID_FILE}")" >>"${GITHUB_OUTPUT}"
    fi
  fi
}

poll_job() {
  require_file "${workspace}/${LOG_ID_FILE}" 'run the submit-job step first'

  export_plugin_poll_job
  run_bridge poll-job
}

all_steps() {
  get_token
  submit_job
  poll_job
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
byggsteg-github - run a Byggsteg job from a GitHub Actions workflow

Usage: byggsteg-github <step>

Steps:
  get-token    sign in to Byggsteg and keep the session token
  submit-job   submit the job, and keep the id of the log it will write to
  poll-job     follow that log, print the job's output, pass or fail the job
  all          the three, in that order, in one step
  help         this message

Settings (the action's inputs, seen here as environment variables):

  BYGGSTEG_STEP                    the step to run, when it is not the argument
  BYGGSTEG_URL                     base URL of the Byggsteg deployment
                                   (https://byggsteg.jointhefreeworld.org)
  BYGGSTEG_EMAIL                   account email                               (get-token)
  BYGGSTEG_PASSWORD                account password                            (get-token)
  BYGGSTEG_TASKS                   tasks to run, space-separated       (submit-job)
  BYGGSTEG_DAEMON_NAME             the daemon the job is for, if any   (submit-job)
  BYGGSTEG_JOB_CODE                the Lisp job definition, instead of     (submit-job)
                                   TASKS
  BYGGSTEG_PROJECT                 project name (the repository's name)
  BYGGSTEG_BRANCH                  branch (the ref this run is about)
  BYGGSTEG_CLONE_URL               where the daemon clones from
                                   (<server>/<owner>/<repo>.git)
  BYGGSTEG_POLL_LIMIT              status polls before giving up (4096)        (poll-job)
  BYGGSTEG_POLL_INTERVAL_SECONDS   seconds between polls (8)                   (poll-job)
  BYGGSTEG_POLL_VIEW               rendered (default) or raw                   (poll-job)
  BYGGSTEG_IMAGE                   the step image
                                   (docker.io/jjba23/byggsteg-woodpecker:v0.3.0)
  BYGGSTEG_RUNTIME                 auto (docker, else podman), docker, podman
                                   or script
  BYGGSTEG_BRIDGE_SCRIPT           the bridge script, when the runtime is
                                   script
  BYGGSTEG_WORKSPACE               the directory the steps share
                                   ($RUNNER_TEMP/byggsteg)

Tuning of the bridge itself, passed through when set: BYGGSTEG_DEBUG,
BYGGSTEG_RETRY_ATTEMPTS, BYGGSTEG_RETRY_INTERVAL, BYGGSTEG_CONNECT_TIMEOUT,
BYGGSTEG_REQUEST_TIMEOUT.
EOF
}

main() {
  local step="${1:-$(setting BYGGSTEG_STEP)}"

  case "${step}" in
    get-token | submit-job | poll-job | all | help | -h | --help | usage) ;;
    '')
      usage 1>&2
      error_exit 'no step given: name one of get-token, submit-job, poll-job or all'
      ;;
    *)
      error_exit "unknown step '${step}': name one of get-token, submit-job, poll-job or all"
      ;;
  esac

  if [[ "${step}" == 'help' || "${step}" == '-h' || "${step}" == '--help' || "${step}" == 'usage' ]]; then
    usage
    exit 0
  fi

  # Every setting is read and resolved before anything is attempted, so a
  # missing one is a message rather than a container that starts to fail.
  url="$(setting BYGGSTEG_URL)"
  url="${url:-${DEFAULT_URL}}"
  if [[ ! ${url} =~ ^https?://[^[:space:]]+$ ]]; then
    error_exit "BYGGSTEG_URL must be an http:// or https:// address, not '${url}'"
  fi

  image="$(setting BYGGSTEG_IMAGE)"
  image="${image:-${DEFAULT_IMAGE}}"

  email="$(setting BYGGSTEG_EMAIL)"
  password="$(setting BYGGSTEG_PASSWORD)"

  resolve_addresses
  resolve_workspace
  resolve_runtime

  log_info "Byggsteg at ${url} (${step})"
  log_debug "Image: ${image}"

  case "${step}" in
    get-token) get_token ;;
    submit-job) submit_job ;;
    poll-job) poll_job ;;
    all) all_steps ;;
  esac
}

main "$@"
