# syntax=docker/dockerfile:1
#
# Ephemeral self-hosted GitHub Actions runner, designed to run next to a Docker-in-Docker
# sidecar (compose.yaml) and to be started by the supervisor with a single-use
# just-in-time runner config (supervisor/runner-supervisor.ps1). The image holds no secrets. Every tool is pinned to an exact version and verified against
# its published checksum or signed package repository. Bump versions in this file only,
# through a reviewed pull request; see README.md "Updating".

# Base image pinned by digest (Dependabot keeps it current).
FROM ubuntu:24.04@sha256:2198e4c65076e9cb0b3d695219df667c0e3b0072da64ca3c2648aca17dcecaf5

# GitHub Actions runner: https://github.com/actions/runner/releases (SHA-256 from the release notes)
ARG RUNNER_VERSION=2.338.2
ARG RUNNER_SHA256=baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40
# PowerShell: https://github.com/PowerShell/PowerShell/releases (SHA-256 from the release notes / hashes.sha256)
ARG POWERSHELL_VERSION=7.7.0
ARG POWERSHELL_SHA256=c89d9c682d2c403dfe726f3df948e359675235a5bd6fab535776de69729ca0cb
# Node.js: https://nodejs.org/dist/v<version>/SHASUMS256.txt
ARG NODE_VERSION=24.22.3
ARG NODE_SHA256=4f2b175a6d53a5c617a80dba2676238a0688cef28c6da4eba35c7d844e66fcfb
# npm: upgraded from the version bundled with Node.js to pick up fixes in its dependencies.
ARG NPM_VERSION=11.21.2
# .NET SDKs, side by side: https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/<channel>/releases.json (SHA-512)
ARG DOTNET_SDK_10_VERSION=10.0.404
ARG DOTNET_SDK_10_SHA512=577d0eb17fec33d029104c5c63a1ab0accc3e28776274abef2218dbac5af18d2109b5406d26b31d76f5c245215e3ba0926a94c20246c672c41847c9e1eb1dc50
ARG DOTNET_SDK_11_VERSION=11.0.100
ARG DOTNET_SDK_11_SHA512=1bec9cca2ec689b1e80245b84f2b53c9441d1aa6daccf2ceb27490768bffa95954fa585bd275def31069d874d543d9ba9e6591fe9ade2dbd9f34ec5c0fd0050c
# Docker CLI (client only) from Docker's signed apt repository; keep in step with the dind sidecar.
ARG DOCKER_CLI_VERSION=29.10.1
ARG DOCKER_REPO_SIGNING_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
# Docker Compose plugin: https://github.com/docker/compose/releases (docker-compose-linux-x86_64.sha256)
ARG COMPOSE_VERSION=5.7.1
ARG COMPOSE_SHA256=af426722a8af5de812fcee30cc1c39f0639f5f723cbadefb25e5d4db054064cf
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
      apt libapt-pkg6.0t64 ca-certificates curl git gnupg jq tar unzip xz-utils \
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

# .NET SDKs.
RUN mkdir -p "${DOTNET_ROOT}" \
 && for sdk in "${DOTNET_SDK_10_VERSION} ${DOTNET_SDK_10_SHA512}" "${DOTNET_SDK_11_VERSION} ${DOTNET_SDK_11_SHA512}"; do \
      set -- $sdk \
      && curl -fsSL -o /tmp/dotnet.tar.gz "https://builds.dotnet.microsoft.com/dotnet/Sdk/$1/dotnet-sdk-$1-linux-x64.tar.gz" \
      && echo "$2  /tmp/dotnet.tar.gz" | sha512sum -c - \
      && tar -xzf /tmp/dotnet.tar.gz -C "${DOTNET_ROOT}" \
      && rm /tmp/dotnet.tar.gz || exit 1; \
    done \
 && ln -s "${DOTNET_ROOT}/dotnet" /usr/bin/dotnet

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
