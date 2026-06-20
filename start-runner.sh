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

# Function to check all values of a comma separated list are integers
function check_all_integers() {
        IFS=',' read -ra _values <<< "$1"
        for value in "${_values[@]}"; do
                if [[ ! "$value" =~ ^[0-9]+$ ]]; then
                        echo "$value"
                        return 1
                fi
        done
        return 0
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

# Retry wait time in secounds
WAIT_SEC=10

#
# INPUT
#

# GitHub Actions inputs
# Set the GitHub Personal Access Token (PAT).
# Retrieves the value from the INPUT_GITHUB_TOKEN environment variable.
#MY_GITHUB_TOKEN=${GITHUB_TOKEN}
#if [[ -z "$MY_GITHUB_TOKEN" ]]; then
#       exit_with_failure "GitHub Personal Access Token (PAT) token is required!"
#fi

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

MY_RUNNER_LABELS=${RUNNER_LABELS}
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

# Set the name of the instance (default: gh-runner-$RANDOM)
# If INPUT_NAME is set, use its value; otherwise, generate a random name using "gh-runner-$RANDOM".
MY_RUNNER_NAME=${NAME:-"gh-runner-$RANDOM"}

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

#
MY_GITHUB_RUNNER_TOKEN_FILE=$(mktemp)

#
if [[ "${MY_GITHUB_SCOPE}" == "repo" ]]; then

    REGISTRATION_URL="https://api.github.com/repos/${MY_GITHUB_REPOSITORY}/actions/runners/registration-token"
else

    REGISTRATION_URL="https://api.github.com/orgs/${MY_GITHUB_ORGANIZATION}/actions/runners/registration-token"
fi

echo "${REGISTRATION_URL}"

# Create GitHub Actions registration token
echo "Create GitHub Actions Runner registration token..."

HTTP_CODE=$(curl -sSL \
        -X "POST" \
        -o "${MY_GITHUB_RUNNER_TOKEN_FILE}" \
        -w "%{http_code}" \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${MY_GITHUB_TOKEN}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${REGISTRATION_URL}"
)

if [[ "${HTTP_CODE}" != "201" ]]; then

    echo "GitHub API returned HTTP ${HTTP_CODE}."

    if jq -e '.message' "${MY_GITHUB_RUNNER_TOKEN_FILE}" >/dev/null 2>&1; then

        # echo "GitHub error: $(jq -r '"\(.message) \(.errors // empty)"' "${MY_GITHUB_RUNNER_TOKEN_FILE}")"
        echo "GitHub error: $(jq -r '[.message, .errors] | map(select(. != null)) | join(" - ")' "${MY_GITHUB_RUNNER_TOKEN_FILE}")"

    else

        echo "Unexpected response:"
        cat "${MY_GITHUB_RUNNER_TOKEN_FILE}"

    fi

    rm -f "${MY_GITHUB_RUNNER_TOKEN_FILE}"

    exit_with_failure "Failed to retrieve GitHub Actions Runner registration token!"
fi

# Read registration token
MY_GITHUB_RUNNER_REGISTRATION_TOKEN=$(jq -er '.token' < "${MY_GITHUB_RUNNER_TOKEN_FILE}")

#
rm -f "${MY_GITHUB_RUNNER_TOKEN_FILE}"

echo -e "✓ Registration token created."

echo -e "<<<< STEP 3 Ende  <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<\n"


echo -e ">>>> STEP 4 Start >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
echo "Configuring runner: ${MY_RUNNER_NAME}"

# alte Konfig entfernen (wichtig bei restart: always oder restart_policy: on-failure)
rm -f .runner .credentials .credentials_rsaparams || true

#
if [[ "${MY_GITHUB_SCOPE}" == "repo" ]]; then
    RUNNER_URL="https://github.com/${MY_GITHUB_REPOSITORY}"
    RUNNER_GROUP_PARAM=""
else
    RUNNER_URL="https://github.com/${MY_GITHUB_ORGANIZATION}"
    RUNNER_GROUP_PARAM="--runnergroup ${MY_RUNNER_GROUP}"
fi

#
su -s /bin/bash "${MY_RUNNER_USER}" -c "
cd '${MY_RUNNER_DIR}'

./config.sh \
  --url '${RUNNER_URL}' \
  --token '${MY_GITHUB_RUNNER_REGISTRATION_TOKEN}' \
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


echo -e ">>>> STEP 5 Start >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
echo "Starting runner..."
exec su -s /bin/bash "${MY_RUNNER_USER}" -c "
cd '${MY_RUNNER_DIR}'
exec ./run.sh
"
