#!/usr/bin/env bash

set -Eeuo pipefail

# Copyright 2024-2025 Nils Knieling. All Rights Reserved.
# Copyright 2026 Daniel Wydler. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

function exit_with_failure() {
        echo >&2 "FAILURE: $1"  # Print error message to stderr
        exit 1
}

function exit_with_config_error() {
        echo >&2 "CONFIGURATION ERROR: $1"
        echo >&2 "Exiting with code 0"
        exit 0
}

#
function github_api() {
    local method="$1"
    local url="$2"

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --connect-timeout 5 \
        --max-time 15 \
        --retry 3 \
        --retry-delay 2 \
        -X "$method" \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${MY_GITHUB_TOKEN}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$url"
}

#
# Returns the GitHub URL depending on the configured runner scope.
#
# Returns:
#   https://github.com/<organization>
#   https://github.com/<owner>/<repository>
function github_get_runner_url() {

    case "${MY_GITHUB_SCOPE}" in

        org)
            echo "https://github.com/${MY_GITHUB_ORGANIZATION}"
            ;;

        repo)
            echo "https://github.com/${MY_GITHUB_REPOSITORY}"
            ;;

        *)
            exit_with_failure "Unsupported GitHub scope '${MY_GITHUB_SCOPE}'"
            ;;
    esac
}

#
# Returns the GitHub Actions Runner API endpoint depending on the
# configured runner scope.
#
# Returns:
#   https://api.github.com/orgs/<organization>/actions/runners
#   https://api.github.com/repos/<owner>/<repository>/actions/runners
function github_get_runners_api_url() {

    case "${MY_GITHUB_SCOPE}" in

        org)
            echo "https://api.github.com/orgs/${MY_GITHUB_ORGANIZATION}/actions/runners"
            ;;

        repo)
            echo "https://api.github.com/repos/${MY_GITHUB_REPOSITORY}/actions/runners"
            ;;

        *)
            exit_with_failure "Unsupported GitHub scope '${MY_GITHUB_SCOPE}'"
            ;;
    esac
}

#
# Returns the GitHub Actions Runner registration token API endpoint.
#
# Returns:
#   https://api.github.com/orgs/<organization>/actions/runners/registration-token
#   https://api.github.com/repos/<owner>/<repository>/actions/runners/registration-token
function github_get_registration_token_api_url() {

    echo "$(github_get_runners_api_url)/registration-token"
}


#
function github_get_registration_token() {

    #
    github_api POST "$(github_get_registration_token_api_url)" | jq -er '.token'
}

# Check the current status of the GitHub Actions runner.
# Supports both organization and repository scoped runners.
# Queries the matching GitHub API endpoint based on GITHUB_SCOPE.
# Returns:
#   true  - runner is currently processing a job (busy/active).
#   false - runner is idle or was not found.
function github_get_runner_busy() {

    # Query GitHub API and find the runner by its unique name
    # The runner name is passed safely as a jq variable
    github_api GET "$(github_get_runners_api_url)" \
    | jq -r --arg name "$MY_RUNNER_NAME" '

        # Iterate through all registered runners
        .runners[]

        # Select the runner matching the current container runner name
        | select(.name == $name)

        # Return the busy state, defaulting to false if missing
        | .busy // false
    '
}

# Cleanup runner registration on container shutdown.
# Checks if the GitHub Actions runner is currently processing a job.
#
# If the runner is busy:
#   - Do not stop the runner process.
#   - Detach the runner process from the cleanup handler.
#   - Keep the container alive until the running workflow finishes.
#
# If the runner is idle:
#   - Stop the runner process gracefully.
#   - Wait for the process to exit.
#   - Remove the runner registration from GitHub.
#
# This prevents active workflows from being interrupted during
# Docker Swarm updates or container shutdown events.
function github_delete_runner_cleanup() {

    # Mark the beginning of the cleanup procedure
    echo ">>>> CLEANUP START >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"

    # Log that a shutdown signal was received
    echo "SIGTERM received → checking runner state"

    # Query GitHub API to check if this runner is currently busy
    # BUSY=$(github_get_runner_busy)
        if ! BUSY=$(github_get_runner_busy); then
                echo "Unable to determine runner state."
                BUSY=false
    fi

    # Check if the runner is processing an active workflow job
    if [[ "${BUSY}" == "true" ]]; then

        # Active runner detected: do not terminate the workflow
        echo "Runner is BUSY → ignoring SIGTERM until job finishes"

        # Do not kill runner.
        # Wait until the GitHub runner process exits after job completion.
        while kill -0 "${RUNNER_PID}" 2>/dev/null; do
        sleep 5
        done

        echo "Runner finished after graceful shutdown delay"

        exit 0
    fi

    # Runner is idle and can be safely stopped
    echo "Runner idle → safe shutdown"

    # Send SIGTERM to allow the runner to stop gracefully
    kill -TERM "${RUNNER_PID}" 2>/dev/null || true

    # Wait until the runner process has fully terminated
    wait "${RUNNER_PID}" || true

    #
    MY_GITHUB_RUNNER_TOKEN=$(github_get_registration_token)

    # Remove the runner registration from GitHub
    # This prevents stale offline runners after container removal
    echo "Removing runner registration..."

    # Execute removal as the runner user because config.sh
    # was created under this user account
    run_as_runner "
        ./config.sh remove --token '${MY_GITHUB_RUNNER_TOKEN}'
    " || echo "Runner removal failed"

    # Mark the end of the cleanup procedure
    echo "<<<< CLEANUP END <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<"

    # Exit successfully after cleanup
    exit 0
}

#
function github_validate_runner_group() {

    local group="$1"

    if [[ "${MY_GITHUB_SCOPE}" != "org" ]]; then
        return 0
    fi

    if ! github_api GET \
      "https://api.github.com/orgs/${MY_GITHUB_ORGANIZATION}/actions/runner-groups" \
      | jq -e --arg name "${group}" '
          .runner_groups[]
          | select(.name == $name)
        ' >/dev/null
    then
        exit_with_config_error \
          "GitHub Runner Group '${group}' does not exist or is not accessible."
    fi
}

# Execute one or more commands as the runner user.
# The current working directory is changed to the runner installation
# directory before executing the supplied command.
function run_as_runner() {

        #
    local command="$1"

        #
        [[ -d "${MY_RUNNER_DIR}" ]] \
    || exit_with_failure "Runner directory '${MY_RUNNER_DIR}' does not exist."

        #
    su -s /bin/bash "${MY_RUNNER_USER}" -c "
        cd '${MY_RUNNER_DIR}' || exit 1
        ${command}
    "
}


# Define required commands
MY_COMMANDS=(
        curl
        cut
        jq
        getent
        su
        id
        chown
)
# Check if required commands are available
for MY_COMMAND in "${MY_COMMANDS[@]}"; do
        if ! command -v "$MY_COMMAND" >/dev/null 2>&1; then
                exit_with_failure "The command '$MY_COMMAND' was not found. Please install it."
        fi
done


#
# INPUT
#

# Read GitHub token from Docker secret.
# The secret is mounted by Docker at /run/secrets/github_token.
if [[ -f "/run/secrets/github_token" ]]; then
#    MY_GITHUB_TOKEN=$(cat /run/secrets/github_token)
    MY_GITHUB_TOKEN=$(tr -d '\n\r' < /run/secrets/github_token)
else
    exit_with_failure "GitHub token secret not found!"
fi


MY_RUNNER_GROUP=${RUNNER_GROUP}
if [[ -z "$MY_RUNNER_GROUP" ]]; then
        exit_with_failure "GitHub Runner Group is required!"
fi

MY_RUNNER_LABELS=${RUNNER_LABELS},${IMAGE_VERSION}
if [[ -z "$MY_RUNNER_LABELS" ]]; then
        exit_with_failure "GitHub Runner Labels are required!"
fi

# Set the GitHub repository name.
# This retrieves the value from the GITHUB_ACTION_REPOSITORY environment variable,
# which is automatically set in GitHub Actions workflows.
# https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/store-information-in-variables#default-environment-variables
MY_GITHUB_SCOPE=${GITHUB_SCOPE:-"org"}
MY_GITHUB_ORGANIZATION=${GITHUB_ORGANIZATION:-""}
MY_GITHUB_REPOSITORY=${GITHUB_REPOSITORY:-""}

case "${MY_GITHUB_SCOPE}" in

    org)
        if [[ -z "${MY_GITHUB_ORGANIZATION}" ]]; then
            exit_with_failure "GITHUB_ORGANIZATION is required for organization runner"
        fi
        ;;

    repo)
        if [[ -z "${MY_GITHUB_REPOSITORY}" ]]; then
            exit_with_failure "GITHUB_REPOSITORY is required for repository runner"
        fi
        ;;

    *)
        exit_with_failure "GITHUB_SCOPE must be 'org' or 'repo'"
        ;;

esac

#
github_validate_runner_group "${MY_RUNNER_GROUP}"

# Use the container hostname as the unique GitHub Actions Runner name.
# In Docker Swarm the hostname is generated from the unique task ID, preventing runner name collisions across redeployments.
MY_RUNNER_NAME=${HOSTNAME}

# Check allowed characters
if [[ ! "$MY_RUNNER_NAME" =~ ^[a-zA-Z0-9_-]{1,64}$ ]]; then
        exit_with_failure "'$MY_RUNNER_NAME' is not a valid hostname or label!"
fi

# Set default GitHub Actions Runner version (default: latest)
# If INPUT_RUNNER_VERSION is set, its value is used. Otherwise, the default value "latest" is used.
# Releases: https://github.com/actions/runner/releases
MY_RUNNER_VERSION=${INPUT_RUNNER_VERSION:-"latest"}
# Check allowed values
if [[ "$MY_RUNNER_VERSION" != "latest" && "$MY_RUNNER_VERSION" != "skip" && ! "$MY_RUNNER_VERSION" =~ ^[0-9\.]{1,63}$ ]]; then
        exit_with_failure "'$MY_RUNNER_VERSION' is not a valid GitHub Actions Runner version! Enter 'latest', 'skip' or the version without 'v'."
fi

# Define the system user under which the GitHub Actions runner will be installed and executed
MY_RUNNER_USER="runner"


echo -e ">>>> STEP 1 Start >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
if ! id "${MY_RUNNER_USER}" >/dev/null 2>&1; then
    echo "Creating runner user..."
    useradd -m -s /bin/bash "${MY_RUNNER_USER}"
fi

echo "Detected home directory of '${MY_RUNNER_USER}'."
RUNNER_HOME=$(getent passwd "${MY_RUNNER_USER}" | cut -d: -f6)

if [[ -z "${RUNNER_HOME}" ]]; then
    exit_with_failure "Could not determine home directory for user ${MY_RUNNER_USER}"
fi

echo "Setting GitHub Actions runner installation directory."
MY_RUNNER_DIR="${RUNNER_HOME}/actions-runner"

echo "Setting GitHub Actions workspace directory."
MY_WORK_DIR="${RUNNER_HOME}/work"


echo
echo -e "<<<< STEP 1 Ende  <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<\n"


echo -e ">>>> STEP 2 Start >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
echo -e "Start installation of GitHub Actions Runner..."
bash install.sh -v "${MY_RUNNER_VERSION}" -d "${MY_RUNNER_DIR}"

echo -e "Setting ownership of runner directory to user 'runner'."
chown -R "${MY_RUNNER_USER}":"${MY_RUNNER_USER}" "${MY_RUNNER_DIR}"

echo -e "<<<< STEP 2 Ende  <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<\n"


echo -e ">>>> STEP 3 Start >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"

# Display
echo "Create GitHub Actions Runner registration token..."

# Create GitHub Actions registration token
MY_GITHUB_RUNNER_TOKEN=$(github_get_registration_token)

# Display
echo -e "✓ Registration token created."

echo -e "<<<< STEP 3 Ende  <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<\n"


echo -e ">>>> STEP 4 Start >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
echo "Configuring runner: ${MY_RUNNER_NAME}"

# alte Konfig entfernen (wichtig bei restart: always oder restart_policy: on-failure)
#rm -f .runner .credentials .credentials_rsaparams || true
rm -f \
    "${MY_RUNNER_DIR}/.runner" \
    "${MY_RUNNER_DIR}/.credentials" \
    "${MY_RUNNER_DIR}/.credentials_rsaparams"

#
RUNNER_URL=$(github_get_runner_url)

#
if [[ "${MY_GITHUB_SCOPE}" == "repo" ]]; then
    RUNNER_GROUP_PARAM=""
else
    RUNNER_GROUP_PARAM="--runnergroup ${MY_RUNNER_GROUP}"
fi

#
run_as_runner "

./config.sh \
  --url '${RUNNER_URL}' \
  --token '${MY_GITHUB_RUNNER_TOKEN}' \
  --name '${MY_RUNNER_NAME}' \
  --labels '${MY_RUNNER_LABELS}' \
  ${RUNNER_GROUP_PARAM} \
  --work '${MY_WORK_DIR}' \
  --ephemeral \
  --unattended \
  --replace
"

echo -e "✓ Configuration was successfully."
echo -e "<<<< STEP 4 Ende  <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<\n"

#
trap 'echo "SIGTERM received"; github_delete_runner_cleanup' SIGTERM
trap 'echo "SIGINT received"; github_delete_runner_cleanup' SIGINT


echo -e ">>>> STEP 5 Start >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
echo "Starting runner..."
run_as_runner "
  exec ./run.sh
" &

# Store the background process ID.
# Used by github_delete_runner_cleanup() to stop or monitor the runner process.
RUNNER_PID=$!

# Wait until the runner process exits.
# The exit code is preserved and forwarded to Docker.
wait "${RUNNER_PID}"

# Store the runner exit code.
# GitHub Actions runner returns non-zero codes on failures.
EXIT_CODE=$?

# Log the runner shutdown result.
echo "Runner exited with code ${EXIT_CODE}"

# Exit with the same code as the runner process.
# Allows Docker Swarm restart policies to react correctly.
exit "${EXIT_CODE}"
