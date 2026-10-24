# syntax=docker/dockerfile:1
#
# Ephemeral self-hosted GitHub Actions runner, designed to run next to a Docker-in-Docker
# sidecar (compose.yaml) and to be started by the host-side supervisor with a single-use
# just-in-time runner config (supervisor/runner-supervisor.ps1). The image holds no secrets. Every tool is pinned to an exact version and verified against
# its published checksum or signed package repository. Bump versions in this file only,
# through a reviewed pull request; see README.md "Updating".

# Base image pinned by digest (Dependabot keeps it current).
FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55

# GitHub Actions runner: https://github.com/actions/runner/releases (SHA-256 from the release notes)
ARG RUNNER_VERSION=2.338.1
ARG RUNNER_SHA256=08e9ccb3604d2462c24b5e33604dc30810296ca15cc65f23cffd4317eb144c37
# PowerShell: https://github.com/PowerShell/PowerShell/releases (SHA-256 from the release notes / hashes.sha256)
ARG POWERSHELL_VERSION=7.6.8
ARG POWERSHELL_SHA256=59112e38ad83350e4f6dc0195953c66b5926792f300ca2e7691b8242e7a16e7f
# Node.js: https://nodejs.org/dist/v<version>/SHASUMS256.txt
ARG NODE_VERSION=24.21.0
ARG NODE_SHA256=fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6
# npm: upgraded from the version bundled with Node.js to pick up fixes in its dependencies.
ARG NPM_VERSION=11.21.0
# .NET SDK: https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/10.0/releases.json (SHA-512)
ARG DOTNET_SDK_VERSION=10.0.401
ARG DOTNET_SDK_SHA512=51c8b999af9e8dd9998c9edc5944e19a90788862068acd38694e098889054ce8c23d4f0c5cccfa16bf187d044562359e5ee69a9f8ad0bbe913ba90311fbce25b
# Docker CLI (client only) from Docker's signed apt repository; keep in step with the dind sidecar.
ARG DOCKER_CLI_VERSION=29.9.2
ARG DOCKER_REPO_SIGNING_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
# Docker Compose plugin: https://github.com/docker/compose/releases (docker-compose-linux-x86_64.sha256)
ARG COMPOSE_VERSION=5.6.0
ARG COMPOSE_SHA256=40343e21ca777173e69cff5dbafeb37c6f81f3b0d57d9e597f036e95eb63e76a
# Playwright Chromium and its OS dependencies, baked in so e2e jobs don't download browsers.
# Match the consumers' @playwright/test version: each release needs its own browser build.
ARG PLAYWRIGHT_VERSION=1.63.0

ENV DEBIAN_FRONTEND=noninteractive \
    DOTNET_ROOT=/usr/share/dotnet \
    DOTNET_NOLOGO=1 \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    POWERSHELL_TELEMETRY_OPTOUT=1 \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    # The Docker-in-Docker sidecar shares this container's network namespace (compose.yaml).
    DOCKER_HOST=tcp://localhost:2376 \
    DOCKER_TLS_VERIFY=1 \
    DOCKER_CERT_PATH=/certs/client

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Base packages.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg jq tar unzip xz-utils \
      # IANA time zone data: .NET resolves zones such as Europe/London through it.
      tzdata \
      libicu74 libssl3t64 libstdc++6 zlib1g libgcc-s1 \
 && rm -rf /var/lib/apt/lists/*

# Docker CLI from Docker's apt repository, after checking the signing key's fingerprint.
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.asc \
 && gpg --show-keys --with-colons /tmp/docker.asc | grep -q "^fpr:::::::::${DOCKER_REPO_SIGNING_FPR}:" \
 && gpg --dearmor -o /etc/apt/keyrings/docker.gpg /tmp/docker.asc && rm /tmp/docker.asc \
 && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends "docker-ce-cli=5:${DOCKER_CLI_VERSION}-1~ubuntu.24.04~noble" \
 && rm -rf /var/lib/apt/lists/*

# Docker Compose plugin.
RUN curl -fsSL -o /tmp/docker-compose "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
 && echo "${COMPOSE_SHA256}  /tmp/docker-compose" | sha256sum -c - \
 && install -D -m 0755 /tmp/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose \
 && rm /tmp/docker-compose

# PowerShell 7.
RUN curl -fsSL -o /tmp/pwsh.tar.gz "https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/powershell-${POWERSHELL_VERSION}-linux-x64.tar.gz" \
 && echo "${POWERSHELL_SHA256}  /tmp/pwsh.tar.gz" | sha256sum -c - \
 && mkdir -p /opt/microsoft/powershell/7 \
 && tar -xzf /tmp/pwsh.tar.gz -C /opt/microsoft/powershell/7 \
 && chmod +x /opt/microsoft/powershell/7/pwsh \
 && ln -s /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh \
 && rm /tmp/pwsh.tar.gz

# Node.js.
RUN curl -fsSL -o /tmp/node.tar.xz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
 && echo "${NODE_SHA256}  /tmp/node.tar.xz" | sha256sum -c - \
 && mkdir -p /opt/node \
 && tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1 \
 && ln -s /opt/node/bin/node /usr/local/bin/node \
 && ln -s /opt/node/bin/npm /usr/local/bin/npm \
 && ln -s /opt/node/bin/npx /usr/local/bin/npx \
 && rm /tmp/node.tar.xz \
 && npm install --global --no-fund --no-audit "npm@${NPM_VERSION}" \
 && rm -rf /root/.npm

# .NET SDK.
RUN curl -fsSL -o /tmp/dotnet.tar.gz "https://builds.dotnet.microsoft.com/dotnet/Sdk/${DOTNET_SDK_VERSION}/dotnet-sdk-${DOTNET_SDK_VERSION}-linux-x64.tar.gz" \
 && echo "${DOTNET_SDK_SHA512}  /tmp/dotnet.tar.gz" | sha512sum -c - \
 && mkdir -p "${DOTNET_ROOT}" \
 && tar -xzf /tmp/dotnet.tar.gz -C "${DOTNET_ROOT}" \
 && ln -s "${DOTNET_ROOT}/dotnet" /usr/bin/dotnet \
 && rm /tmp/dotnet.tar.gz

# Playwright Chromium with its OS dependencies (npm verifies the package's registry signature).
RUN npx --yes "playwright@${PLAYWRIGHT_VERSION}" install --with-deps chromium \
 && rm -rf /root/.npm /var/lib/apt/lists/*

# The runner. Every job gets a brand-new container (docker run --rm), so it is unpacked straight
# into the runner user's home. It runs JavaScript actions with its bundled Node.js binaries only, so the npm and corepack
# copies bundled with them (never used, and carrying vulnerable dependencies) are removed.
RUN useradd --create-home --uid 1001 --shell /bin/bash runner \
 && curl -fsSL -o /tmp/runner.tar.gz "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
 && echo "${RUNNER_SHA256}  /tmp/runner.tar.gz" | sha256sum -c - \
 && mkdir -p /home/runner/actions-runner \
 && tar -xzf /tmp/runner.tar.gz -C /home/runner/actions-runner \
 && /home/runner/actions-runner/bin/installdependencies.sh \
 && rm -rf /home/runner/actions-runner/externals/node*/lib/node_modules/npm \
           /home/runner/actions-runner/externals/node*/lib/node_modules/corepack \
           /home/runner/actions-runner/externals/node*/bin/npm \
           /home/runner/actions-runner/externals/node*/bin/npx \
           /home/runner/actions-runner/externals/node*/bin/corepack \
 && rm -rf /tmp/runner.tar.gz /var/lib/apt/lists/* \
 && mkdir -p /ms-playwright /home/runner/.nuget /home/runner/.npm \
 && chown -R runner:runner /home/runner /ms-playwright

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

# No secrets and no root at run time: the supervisor passes a single-use JIT runner config.
USER runner
WORKDIR /home/runner
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
