# syntax=docker/dockerfile:1.7
# =============================================================================
# Multi-stage build for a .NET service.
#
# Notes that matter in CI:
#
#  * `--mount=type=secret` requires BuildKit. Set DOCKER_BUILDKIT=1 on the
#    agent or the RUN step below fails with a missing mount.
#
#  * The .npmrc is mounted, used, and discarded within a single RUN layer.
#    Copying it in with `COPY .npmrc .` would persist the auth token in the
#    image history permanently, even if a later layer deletes the file.
#
#  * Ubuntu-based .NET images (8.0-jammy, 9.0-noble and later) do not ship
#    busybox `addgroup`/`adduser`. Dockerfiles carried over from Alpine bases
#    fail here. Use `groupadd`/`useradd`, or the built-in `app` user which
#    Microsoft added to the runtime images from .NET 8 onward.
# =============================================================================

ARG DOTNET_VERSION=8.0

# -----------------------------------------------------------------------------
# Stage 1: restore and publish
# -----------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_VERSION} AS build

ARG PROJECT_PATH
ARG BUILD_NUMBER=0.0.0
WORKDIR /src

# Copy the solution and every project file first, then restore. This layer is
# cached until a .csproj changes, so day-to-day source edits skip the restore.
COPY *.sln ./
COPY src/*/*.csproj ./
RUN for f in *.csproj; do \
      mkdir -p "src/${f%.csproj}" && mv "$f" "src/${f%.csproj}/"; \
    done

# Restore at solution level. Restoring a single project in a multi-project
# solution is the usual cause of MSB3202 ("project file does not exist")
# when that project references another outside the copied paths.
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc \
    dotnet restore

COPY . .

RUN dotnet publish "${PROJECT_PATH}" \
      --configuration Release \
      --no-restore \
      --output /app/publish \
      -p:Version="${BUILD_NUMBER}" \
      -p:UseAppHost=false

# -----------------------------------------------------------------------------
# Stage 2: runtime
# -----------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/aspnet:${DOTNET_VERSION} AS runtime

# curl is required by the container platform's startup probe. The aspnet
# runtime image does not include it.
RUN apt-get update \
    && apt-get install --no-install-recommends -y curl \
    && rm -rf /var/lib/apt/lists/*

# Non-root user. `app` (uid 1654) exists in .NET 8+ runtime images; create it
# only if absent so this Dockerfile works across base image versions.
RUN if ! id app >/dev/null 2>&1; then \
      groupadd --gid 1654 app && \
      useradd --uid 1654 --gid app --create-home --shell /bin/false app; \
    fi

WORKDIR /app
COPY --from=build --chown=app:app /app/publish .

USER app

ENV ASPNETCORE_URLS=http://+:8080 \
    ASPNETCORE_ENVIRONMENT=Production \
    DOTNET_EnableDiagnostics=0

EXPOSE 8080

# Startup probe target. The platform waits for this to succeed before routing
# traffic to a new revision — which is what closes the gap that otherwise
# produces intermittent 502s during rollout.
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
  CMD curl --fail --silent http://localhost:8080/health || exit 1

ENTRYPOINT ["dotnet", "Api.dll"]
