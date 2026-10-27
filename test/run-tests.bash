#!/usr/bin/env bash

# byggsteg-github

# Copyright © Josep Bigorra <jjbigorra@gmail.com>

# byggsteg-github is free software: you can redistribute it and/or modify
# it under the terms of the Lesser GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# byggsteg-github is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# Lesser GNU General Public License for more details.

# You should have received a copy of the Lesser GNU General Public License
# along with byggsteg-github.  If not, see <https://www.gnu.org/licenses/>.

# The tests, in two parts, because there are two questions to answer.
#
#   * What does this project hand the bridge?  The runner is run with a
#     stand-in bridge (test/fake-bridge.bash) that writes down every setting
#     and every name it was handed, so the settings, the job code written from
#     the tasks, the addresses worked out from the GitHub context and the
#     refusals can all be read as facts rather than guessed at from a log.
#   * Does the whole bridge work when it is driven this way?  The runner is
#     then run for real -- the image, and a mock Byggsteg deployment
#     (test/mock-byggsteg.scm) -- so a green pipeline is green because
#     Byggsteg said the job succeeded, which is the thing this project exists
#     to make true.  That part needs a container runtime and the image, and
#     says so rather than failing when a machine has neither.
#
# Run it with:
#
#   bash test/run-tests.bash

set -uo pipefail

# A CDPATH in the caller's environment makes `cd` echo where it landed and
# would end up inside the paths below.
unset CDPATH

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "$test_dir/.." && pwd)"
runner="$root/src/bash/byggsteg-github.bash"
fake="$test_dir/fake-bridge.bash"
mock="$test_dir/mock-byggsteg.scm"

image='docker.io/jjba23/byggsteg-woodpecker:v0.3.0'
port="${BYGGSTEG_TEST_PORT:-8799}"
base="http://127.0.0.1:$port"

state="$(mktemp -d)"
work="$(mktemp -d)"
workspace="$work/workspace"
record="$state/record.txt"
outputs="$state/github-output.txt"
server_pid=''
# Filled in by the image part at the end of this file: the addresses this
# machine may be reached at, and the one a container could get an answer from.
mock_addresses=()
image_base=''
pass=0
fail=0

cleanup() {
  if [[ -n "${server_pid}" ]]; then
    kill "${server_pid}" 2>/dev/null
  fi
  rm -rf "${state}" "${work}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Checking, and reading what was recorded
# ---------------------------------------------------------------------------

check() { # <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    printf '  ok   %s\n' "$1"
    pass=$((pass + 1))
  else
    printf '  FAIL %s\n         expected: %q\n         actual:   %q\n' "$1" "$2" "$3"
    fail=$((fail + 1))
  fi
}

# contains <text> <needle> -- 1 when TEXT holds NEEDLE, 0 otherwise.
contains() {
  if [[ "$1" == *"$2"* ]]; then printf 1; else printf 0; fi
}

# counted <text> <literal> -- how many lines of TEXT hold LITERAL.
counted() {
  grep -cF -- "$2" <<<"$1" || true
}

# fresh -- an empty workspace, an empty record and empty outputs, so each
# group of tests starts from nothing.
fresh() {
  rm -rf "${work}"
  mkdir -p "${workspace}"
  : >"${record}"
  : >"${outputs}"
}

# recorded <name> -- what the bridge was handed for NAME, or nothing.
recorded() {
  grep -E "^env $1=" "${record}" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# handed <name> -- 1 when NAME was handed over at all.
handed() {
  if grep -qE "^env $1=" "${record}" 2>/dev/null; then printf 1; else printf 0; fi
}

# stepped -- the step the bridge was asked for.
stepped() {
  grep -E '^step=' "${record}" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# ran_in -- the directory the bridge was run in.
ran_in() {
  grep -E '^cwd=' "${record}" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# readable <file> -- 1 when Guile can read a form from FILE: the job code this
# project writes has to be Lisp a reader accepts, and only a reader can say so.
readable() {
  if guile --no-auto-compile -c "(read (open-input-file \"$1\"))" >/dev/null 2>&1; then
    printf 1
  else
    printf 0
  fi
}

# mode -- how the runs below drive the bridge: `script' runs the stand-in
# bridge directly, `image' runs the real one in its image, the way a GitHub
# runner does.  The second part of this file switches to `image'.
mode='script'

# run <step> [environment...] -- run the runner.
#
# The environment is emptied first: this script's own settings are inherited
# from whoever started the tests, and a test that passes should pass because
# of what it sets rather than because of what the machine happened to hold.
run() {
  local step="$1"
  shift

  # Only the stand-in bridge needs to be pointed at; the image is found the
  # way a workflow finds it, from BYGGSTEG_IMAGE or the default.
  local -a mode_settings=()
  if [[ "${mode}" == 'script' ]]; then
    mode_settings=(
      BYGGSTEG_RUNTIME='script'
      BYGGSTEG_BRIDGE_SCRIPT="${fake}"
      BYGGSTEG_FAKE_RECORD="${record}"
    )
  fi

  (
    cd "${work}" || exit 1
    env -i \
      PATH="${PATH}" \
      HOME="${HOME}" \
      TMPDIR="${TMPDIR:-/tmp}" \
      ${mode_settings[@]+"${mode_settings[@]}"} \
      BYGGSTEG_WORKSPACE="${workspace}" \
      GITHUB_OUTPUT="${outputs}" \
      "$@" \
      bash "${runner}" "${step}"
  )
}

# ---------------------------------------------------------------------------
# What the two doors hand over
#
# The action and the reusable workflow are two ways in, and a setting that one
# of them names and the other forgets is a build that behaves differently
# depending on which one a repository called.  So the two are compared with
# each other, and with what the script reads.  This is a check over the
# metadata rather than over a run, which is the only way to make it without a
# GitHub runner.
# ---------------------------------------------------------------------------

# declared_inputs <file> <start> <end> <indent> -- the input names declared
# between the START and END headings of FILE, at that indentation.
declared_inputs() {
  awk -v start="$2" -v end="$3" '$0 ~ start { inside=1; next } $0 ~ end { inside=0 } inside' "$1" |
    grep -oE "^ {$4}[a-z][a-z0-9-]*:" |
    tr -d ' :' |
    sort -u
}

# used_inputs <file> -- the input names FILE refers to, wherever it does.  An
# input that is declared and then never named is one a caller may set to no
# effect, which is worse than one that does not exist: the workflow looks
# right and the setting never arrives.
used_inputs() {
  grep -oE 'inputs\.[a-z][a-z0-9-]*' "$1" |
    sed 's/inputs\.//' |
    sort -u
}

# action_env -- the settings the action hands its step.  Three names are left
# out, none of them a setting a workflow has a say in: ACTION_PATH is where the
# action itself lives, and BRIDGE_SCRIPT and STEP are the two things a called
# workflow does differently -- it runs the three steps itself, so it takes no
# step to run, and it runs them in the image, so it needs no script to point a
# bare machine at.
action_env() {
  grep -oE '^ +BYGGSTEG_[A-Z0-9_]+:' "$root/action.yml" |
    tr -d ' :' |
    grep -vE '^(BYGGSTEG_ACTION_PATH|BYGGSTEG_BRIDGE_SCRIPT|BYGGSTEG_STEP)$' |
    sort -u
}

# workflow_env -- the BYGGSTEG_* names the reusable workflow hands its job.
workflow_env() {
  grep -oE '^ +BYGGSTEG_[A-Z0-9_]+:' "$root/.github/workflows/byggsteg.yml" |
    tr -d ' :' |
    sort -u
}

# mentioned_in_script -- every BYGGSTEG_* name the runner script knows of.
mentioned_in_script() {
  grep -oE 'BYGGSTEG_[A-Z0-9_]+' "$runner" | sort -u
}

workflow_file="$root/.github/workflows/byggsteg.yml"

echo "the two doors"
check "the script reads every setting the action hands it" '' \
  "$(comm -23 <(action_env) <(mentioned_in_script))"
check "the action hands over or uses every input it declares" '' \
  "$(comm -23 <(declared_inputs "$root/action.yml" '^inputs:' '^outputs:' 2) \
    <(used_inputs "$root/action.yml"))"
check "the workflow uses no input it does not declare" '' \
  "$(comm -23 <(used_inputs "${workflow_file}") \
    <(declared_inputs "${workflow_file}" '^    inputs:' '^    secrets:' 6))"
check "the workflow hands over what the action hands over" \
  "$(action_env)" "$(workflow_env)"

# ---------------------------------------------------------------------------
# What the bridge is handed
# ---------------------------------------------------------------------------

echo "signing in"
fresh
out="$(run get-token \
  BYGGSTEG_URL="${base}" \
  BYGGSTEG_EMAIL='user@example.org' \
  BYGGSTEG_PASSWORD='s3cret' \
  GITHUB_REPOSITORY='jjba23/lucidplan' \
  GITHUB_REF_NAME='trunk' \
  GITHUB_SERVER_URL='https://github.com' 2>&1)"
check "get-token exit 0" 0 "$?"
check "the step the bridge was asked for" 'get-token' "$(stepped)"
check "the address is handed over" "${base}" "$(recorded PLUGIN_BYGGSTEG_URL)"
check "the account is handed over" 'user@example.org' "$(recorded PLUGIN_BYGGSTEG_EMAIL)"
check "the password is handed over" 's3cret' "$(recorded PLUGIN_BYGGSTEG_PASSWORD)"
check "the GitHub context is handed over" 'jjba23/lucidplan' "$(recorded GITHUB_REPOSITORY)"
check "the project is the repository's name" 'lucidplan' "$(recorded BYGGSTEG_PROJECT)"
check "the branch is the run's branch" 'trunk' "$(recorded BYGGSTEG_BRANCH)"
check "the clone address is worked out" 'https://github.com/jjba23/lucidplan.git' \
  "$(recorded BYGGSTEG_CLONE_URL)"
check "the bridge runs in the shared directory" "${workspace}" "$(ran_in)"
check "the bridge's own words reach the build log" 1 \
  "$(counted "$out" 'the fake bridge was asked for get-token')"

echo "handing over a job"
fresh
printf 'test-token-123' >"${workspace}/x-bewaking-byggsteg"
expected_code='(lambda()\n  `((task . ("maak-test" "maak-deploy"))\n    (daemon-name . "my-daemon")\n    (project . "lucidplan")\n    (branch-name . "trunk")\n    (clone-url . "https://github.com/jjba23/lucidplan.git")))'
out="$(run submit-job \
  BYGGSTEG_URL="${base}" \
  BYGGSTEG_TASKS='maak-test maak-deploy' \
  BYGGSTEG_DAEMON_NAME='my-daemon' \
  GITHUB_REPOSITORY='jjba23/lucidplan' \
  GITHUB_REF_NAME='trunk' \
  GITHUB_SERVER_URL='https://github.com' 2>&1)"
check "submit-job exit 0" 0 "$?"
check "the job code is written from the tasks" "${expected_code}" \
  "$(recorded PLUGIN_BYGGSTEG_JOB_CODE)"
printf '%b' "$(recorded PLUGIN_BYGGSTEG_JOB_CODE)" >"${state}/job-code.scm"
check "and it is a form a Lisp reader accepts" 1 "$(readable "${state}/job-code.scm")"
check "the run's log id is handed to the workflow" 'log-id=log-abc-123' "$(cat "${outputs}")"
check "a step that only submits is not signed in as anybody" 0 \
  "$(handed PLUGIN_BYGGSTEG_PASSWORD)"

echo "a job code of one's own"
fresh
printf 'test-token-123' >"${workspace}/x-bewaking-byggsteg"
out="$(run submit-job \
  BYGGSTEG_URL="${base}" \
  BYGGSTEG_JOB_CODE='(lambda() `((task . ("x"))))' \
  BYGGSTEG_PROJECT='somewhere' 2>&1)"
check "a job code is sent as it was written" '(lambda() `((task . ("x"))))' \
  "$(recorded PLUGIN_BYGGSTEG_JOB_CODE)"

echo "following a job"
fresh
printf 'log-abc-123' >"${workspace}/byggsteg-log-id"
run poll-job \
  BYGGSTEG_URL="${base}" \
  BYGGSTEG_POLL_INTERVAL_SECONDS='1' \
  BYGGSTEG_POLL_VIEW='raw' >/dev/null 2>&1
check "poll-job exit 0" 0 "$?"
check "how often to poll is handed over" '1' "$(recorded PLUGIN_POLL_INTERVAL_SECONDS)"
check "how to read the output is handed over" 'raw' "$(recorded PLUGIN_POLL_VIEW)"
check "an unset poll limit keeps the bridge's own default" 0 \
  "$(handed PLUGIN_POLL_LIMIT)"
check "a step that only follows a log is not signed in as anybody" 0 \
  "$(handed PLUGIN_BYGGSTEG_EMAIL)"

echo "refusals"
fresh
out="$(run submit-job BYGGSTEG_URL="${base}" BYGGSTEG_TASKS='x' BYGGSTEG_PROJECT='p' 2>&1)"
check "submit-job without a token is refused" 1 "$?"
check "and says which step to run first" 1 \
  "$(contains "$out" 'run the get-token step first')"

fresh
out="$(run poll-job BYGGSTEG_URL="${base}" 2>&1)"
check "poll-job without a log id is refused" 1 "$?"
check "and says which step to run first" 1 \
  "$(contains "$out" 'run the submit-job step first')"

fresh
printf 'test-token-123' >"${workspace}/x-bewaking-byggsteg"
out="$(run submit-job \
  BYGGSTEG_URL="${base}" \
  BYGGSTEG_PROJECT='p' \
  BYGGSTEG_TASKS='a"b' 2>&1)"
check "a task name that cannot be written into a job code is refused" 1 "$?"
check "and the refusal names the setting" 1 \
  "$(contains "$out" 'BYGGSTEG_TASKS cannot be written into a job code')"

fresh
out="$(run get-token \
  BYGGSTEG_URL="${base}" \
  BYGGSTEG_EMAIL='user@example.org' \
  BYGGSTEG_PASSWORD='s3cret' \
  BYGGSTEG_FAKE_FAIL='1' 2>&1)"
check "a bridge that fails fails the step" 1 "$?"
check "and its own words are in the build log" 1 \
  "$(contains "$out" 'the fake bridge was told to fail')"

# ---------------------------------------------------------------------------
# The whole bridge, through the image
# ---------------------------------------------------------------------------

echo "the whole bridge, through the image"

runtime=''
for candidate in docker podman; do
  if command -v "${candidate}" >/dev/null 2>&1; then
    runtime="${candidate}"
    break
  fi
done

if [[ -z "${runtime}" ]]; then
  printf '  skip  no container runtime on this machine (docker or podman)\n'
elif ! "${runtime}" image inspect "${image}" >/dev/null 2>&1; then
  printf '  skip  the step image is not here, pull it with: %s pull %s\n' "${runtime}" "${image}"
else
  # scenario <name> -- what the mock deployment plays from now on.
  scenario() {
    printf '%s' "$1" >"${state}/scenario"
    : >"${state}/requests.txt"
    : >"${state}/have-values.txt"
  }

  # requests -- what the mock was asked, one "METHOD path" per line.
  requests() {
    cat "${state}/requests.txt" 2>/dev/null || printf ''
  }

  scenario success
  guile --no-auto-compile "${mock}" "${port}" "${state}" >"${state}/server.log" 2>&1 &
  server_pid=$!
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "${base}/" && break
    sleep 0.2
  done

  # The steps run in a container, which has a network of its own: the mock is
  # on this machine, but not at the loopback address as seen from in there.
  # Rather than assume one runtime's answer, the addresses the machine can be
  # reached at are tried, and the first one a container can get an HTTP status
  # out of is the deployment's address for the runs below.
  mock_addresses=(host.containers.internal host.docker.internal 10.0.2.2 172.17.0.1)
  if command -v ip >/dev/null 2>&1; then
    while read -r address; do
      [[ -n "${address}" ]] && mock_addresses+=("${address}")
    done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
  fi

  image_base=''
  for address in "${mock_addresses[@]}"; do
    code="$("${runtime}" run --rm --entrypoint curl "${image}" \
      -s -o /dev/null -m 3 -w '%{http_code}' "http://${address}:${port}/" 2>/dev/null || true)"
    if [[ "${code}" =~ ^[1-5][0-9][0-9]$ ]]; then
      image_base="http://${address}:${port}"
      break
    fi
  done

fi

# The runs themselves, in a function so that a machine whose containers cannot
# reach the mock skips them as a group rather than failing every one of them.
image_tests() {
  fresh
  scenario success
  out="$(run all \
    BYGGSTEG_URL="${image_base}" \
    BYGGSTEG_EMAIL='user@example.org' \
    BYGGSTEG_PASSWORD='s3cret' \
    BYGGSTEG_TASKS='maak-test maak-deploy' \
    BYGGSTEG_DAEMON_NAME='test-daemon' \
    BYGGSTEG_POLL_INTERVAL_SECONDS='1' \
    BYGGSTEG_DEBUG='1' \
    GITHUB_REPOSITORY='jjba23/lucidplan' \
    GITHUB_REF_NAME='trunk' \
    GITHUB_SERVER_URL='https://github.com' 2>&1)"
  check "one step, three calls: exit 0" 0 "$?"
  check "the job's own output reaches the build log" 1 \
    "$(counted "$out" 'hello from the byggsteg job')"
  check "the deployment was signed in to" 1 \
    "$(counted "$(requests)" 'POST /api/v2/login')"
  check "a job was queued" 1 "$(counted "$(requests)" 'POST /api/v2/jobs')"
  check "the log it writes to was followed" 1 \
    "$(contains "$(requests)" 'GET /api/v2/logs/log-abc-123')"
  check "and only what had not been printed yet was asked for" 1 \
    "$(contains "$(requests)" 'have=')"
  check "the job code named the project" 1 "$(contains "$out" '(project . "lucidplan")')"
  check "the job code named the branch" 1 "$(contains "$out" '(branch-name . "trunk")')"
  check "the job code named the clone address" 1 \
    "$(contains "$out" '(clone-url . "https://github.com/jjba23/lucidplan.git")')"
  check "the run's log id is handed to the workflow" 'log-id=log-abc-123' "$(cat "${outputs}")"

  fresh
  scenario failure
  out="$(run all \
    BYGGSTEG_URL="${image_base}" \
    BYGGSTEG_EMAIL='user@example.org' \
    BYGGSTEG_PASSWORD='s3cret' \
    BYGGSTEG_TASKS='maak-test' \
    BYGGSTEG_POLL_INTERVAL_SECONDS='1' \
    GITHUB_REPOSITORY='jjba23/lucidplan' 2>&1)"
  check "a job that failed fails the build" 1 "$?"
  check "and what it printed is in the build log" 1 \
    "$(counted "$out" 'hello from the byggsteg job')"

  fresh
  scenario login-unauthorized
  out="$(run get-token \
    BYGGSTEG_URL="${image_base}" \
    BYGGSTEG_EMAIL='user@example.org' \
    BYGGSTEG_PASSWORD='wrong' 2>&1)"
  check "a password the deployment refuses fails the step" 1 "$?"
  check "one call, and no retrying of a refusal" 1 "$(wc -l <"${state}/requests.txt")"
}

if [[ -z "${runtime}" ]]; then
  : # said above: there is no container runtime here
elif [[ -z "${image_base}" ]]; then
  printf '  skip  no container here can reach this machine on port %s (tried: %s)\n' \
    "${port}" "${mock_addresses[*]}"
else
  mode='image'
  image_tests
fi

echo
printf '%d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" == 0 ]]
