#!/bin/bash
# What a CI job's Linux container needs beyond its image, installed when
# missing (as Visor's tools/ci/job_tools.sh): Swift's own image (by digest,
# on GitHub's ubuntu-24.04-arm) has Swift, clang, lld, git and readelf, but
# not curl (protoc's download) or Python (tools/ci/tests_proof.py,
# proof_diff.py, and protoc's unzip). As root, or by sudo.
#
#   tools/ci/job_tools.sh
set -euo pipefail
root_do() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }

# Each command, by the package that has it.
wanted=(git:git curl:curl python3:python3 unzip:unzip sha256sum:coreutils readelf:binutils ld.lld:lld)
packages=(ca-certificates)
for pair in "${wanted[@]}"; do
    command -v "${pair%%:*}" > /dev/null || packages+=("${pair#*:}")
done
if [ ${#packages[@]} -gt 1 ]; then
    root_do apt-get update -qq > /dev/null
    root_do env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${packages[@]}" > /dev/null
fi
# The checkout belongs to the runner's user, not the container's.
git config --global --add safe.directory "${GITHUB_WORKSPACE:-$PWD}"
echo "job_tools: $(swift --version 2>&1 | head -1), $(git --version), $(python3 --version), $(uname -m)"
