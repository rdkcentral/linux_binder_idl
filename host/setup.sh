#!/usr/bin/env bash

#/**
# * Copyright 2024 Comcast Cable Communications Management, LLC
# *
# * Licensed under the Apache License, Version 2.0 (the "License");
# * you may not use this file except in compliance with the License.
# * You may obtain a copy of the License at
# *
# * http://www.apache.org/licenses/LICENSE-2.0
# *
# * Unless required by applicable law or agreed to in writing, software
# * distributed under the License is distributed on an "AS IS" BASIS,
# * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# * See the License for the specific language governing permissions and
# * limitations under the License.
# *
# * SPDX-License-Identifier: Apache-2.0
# */

# Set up Python virtual environment and install dependencies
# REPO_ROOT = where the script is sourced from (the caller's current dir)

set -e

# Path of the script itself (absolute)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Path where script is sourced from (user’s working directory)
REPO_ROOT="$(pwd)"
VENV_PATH="${REPO_ROOT}/.venv"

# --- Auto-detect requirements.txt ---
if [ -f "${SCRIPT_DIR}/requirements.txt" ]; then
    REQUIREMENTS_FILE="${SCRIPT_DIR}/requirements.txt"
elif [ -f "${REPO_ROOT}/requirements.txt" ]; then
    REQUIREMENTS_FILE="${REPO_ROOT}/requirements.txt"
else
    REQUIREMENTS_FILE="$(find "${REPO_ROOT}" -type f -name 'requirements.txt' | head -n 1)"
fi

if [ -z "${REQUIREMENTS_FILE}" ]; then
    echo "❌ No requirements.txt found relative to ${REPO_ROOT} or ${SCRIPT_DIR}"
    return 1 2>/dev/null || exit 1
fi

echo "📂 Sourced from: ${REPO_ROOT}"
echo "📜 Using requirements file: ${REQUIREMENTS_FILE}"
echo "🐍 Virtualenv path: ${VENV_PATH}"

# --- Create venv if missing ---
if [ ! -d "${VENV_PATH}" ]; then
    echo "➡️  Creating virtual environment..."
    python3 -m venv "${VENV_PATH}"
else
    echo "✅ Virtual environment already exists."
fi

# --- Activate and install dependencies ---
# shellcheck disable=SC1090
source "${VENV_PATH}/bin/activate"

pip install --upgrade pip
pip install -r "${REQUIREMENTS_FILE}"

echo "✅ Setup complete. Virtual environment activated."