#!/usr/bin/env bash
# Compares the tool versions pinned in the Dockerfile with the latest upstream releases and
# prints a Markdown table. Exits 0 always; prints "OUTDATED=true" on the last line when any
# pin is behind. Dependabot covers the base and dind images and the GitHub Actions; this
# covers the tools installed by version number.
set -euo pipefail
cd "$(dirname "$0")/.."

pinned() { sed -n "s/^ARG $1=//p" Dockerfile | head -1; }
gh_latest() { curl -fsSL -H "Accept: application/vnd.github+json" ${GH_TOKEN:+-H "Authorization: Bearer ${GH_TOKEN}"} \
  "https://api.github.com/repos/$1/releases/latest" | jq -r .tag_name | sed 's/^v//'; }

declare -A latest
latest[RUNNER_VERSION]=$(gh_latest actions/runner)
latest[POWERSHELL_VERSION]=$(gh_latest PowerShell/PowerShell)
latest[COMPOSE_VERSION]=$(gh_latest docker/compose)
node_major=$(pinned NODE_VERSION | cut -d. -f1)
latest[NODE_VERSION]=$(curl -fsSL https://nodejs.org/dist/index.json | jq -r --arg m "v${node_major}." '[.[] | select(.version | startswith($m))][0].version' | sed 's/^v//')
for key in DOTNET_SDK_10_VERSION DOTNET_SDK_11_VERSION; do
  dotnet_channel=$(pinned "$key" | cut -d. -f1-2)
  latest[$key]=$(curl -fsSL "https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/${dotnet_channel}/releases.json" | jq -r '."latest-sdk"')
done
latest[PLAYWRIGHT_VERSION]=$(curl -fsSL https://registry.npmjs.org/playwright/latest | jq -r .version)
docker_minor=$(pinned DOCKER_CLI_VERSION | cut -d. -f1-2)
latest[DOCKER_CLI_VERSION]=$(curl -fsSL https://download.docker.com/linux/ubuntu/dists/noble/stable/binary-amd64/Packages \
  | awk '/^Package: docker-ce-cli$/{p=1} p&&/^Version:/{print $2; p=0}' \
  | sed -E 's/^5://; s/-1~ubuntu.*$//' | grep "^${docker_minor}\." | sort -V | tail -1)

outdated=false
echo "| Pin | Pinned | Latest | |"
echo "|---|---|---|---|"
for key in RUNNER_VERSION POWERSHELL_VERSION NODE_VERSION DOTNET_SDK_10_VERSION DOTNET_SDK_11_VERSION DOCKER_CLI_VERSION COMPOSE_VERSION PLAYWRIGHT_VERSION; do
  have=$(pinned "$key"); want=${latest[$key]}
  if [ "$key" = PLAYWRIGHT_VERSION ]; then
    # Must match the consumers' @playwright/test version (the browser build is tied to it).
    mark="informational: bump together with consumers' Playwright"
  elif [ -n "$want" ] && [ "$have" != "$want" ]; then mark="update available"; outdated=true; else mark="current"; fi
  echo "| \`$key\` | $have | ${want:-?} | $mark |"
done
echo
echo "OUTDATED=$outdated"
