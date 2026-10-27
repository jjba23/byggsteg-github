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

# A stand-in for the bridge script, used by the tests that are about what this
# project hands the bridge rather than about what the bridge does with it.
#
# It writes down the step it was asked for, the directory it was run in, and
# every setting and every name it was handed -- one line each, with a newline
# escaped as \n so that a job code stays on one line -- and then leaves behind
# the files the real bridge would have left, so the step after it has
# something to read.
#
# Nothing here talks to a deployment: that is what the mock is for.

set -Eeuo pipefail

step="${1:-}"

if [[ -z "${BYGGSTEG_FAKE_RECORD:-}" ]]; then
  printf 'BYGGSTEG_FAKE_RECORD is required: the test must say where to write what it was handed\n' >&2
  exit 2
fi

{
  printf 'step=%s\n' "${step}"
  printf 'cwd=%s\n' "${PWD}"

  # The names a workflow would recognise, and the bridge's own settings. What
  # is *not* here is as much of a fact as what is: a test can ask whether the
  # password was handed to a step that has no business signing in.
  for name in ${!PLUGIN_@} ${!GITHUB_@} ${!BYGGSTEG_@}; do
    value="${!name}"
    printf 'env %s=%s\n' "${name}" "${value//$'\n'/\\n}"
  done
} >"${BYGGSTEG_FAKE_RECORD}"

# What the real bridge sends to stdout, so the tests can check that a job's
# output reaches the log of the build.
printf 'the fake bridge was asked for %s\n' "${step}"

if [[ -n "${BYGGSTEG_FAKE_OUTPUT:-}" ]]; then
  printf '%s\n' "${BYGGSTEG_FAKE_OUTPUT}"
fi

# A bridge that fails, for the tests about a build that must go red.
if [[ -n "${BYGGSTEG_FAKE_FAIL:-}" ]]; then
  printf 'the fake bridge was told to fail\n' >&2
  exit 1
fi

# The files the three steps exchange, as the real bridge writes them.
case "${step}" in
  get-token) printf 'test-token-123' >x-bewaking-byggsteg ;;
  submit-job) printf 'log-abc-123' >byggsteg-log-id ;;
esac
