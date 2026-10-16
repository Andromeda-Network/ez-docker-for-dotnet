# syntax=docker/dockerfile:1
#
# ASP.NET Core image, after https://learn.microsoft.com/dotnet/core/docker/build-container
# `ez dotnet new` copies it to apps/<app>/; copy it to your repository root too, for CI. Build
# from the repository root (the build context is the whole solution):
#
#   docker build -f dotnet.Dockerfile --build-arg PROJECT=src/MyApp/MyApp.csproj -t myapp .
#   docker build -f dotnet.Dockerfile --target test .          # the tests, inside the build
#   docker build -f dotnet.Dockerfile --target migrations ...  # EF Core migrations bundle
#
# Services that are not web apps (workers) use the same file with another PROJECT.

ARG DOTNET_VERSION=10.0

# ---- build ---------------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_VERSION} AS build
ARG PROJECT
ARG CONFIGURATION=Release
WORKDIR /src
COPY . .
# The NuGet cache lives in a BuildKit cache mount: restores are fast without copying each
# .csproj into its own layer first (fragile in multi-project solutions).
RUN --mount=type=cache,id=nuget,target=/root/.nuget/packages \
    test -n "$PROJECT" || { echo "Set --build-arg PROJECT=path/to/App.csproj" >&2; exit 1; }; \
    dotnet restore "$PROJECT"
RUN --mount=type=cache,id=nuget,target=/root/.nuget/packages \
    dotnet publish "$PROJECT" -c "$CONFIGURATION" --no-restore -o /app -p:UseAppHost=false \
    && basename "$PROJECT" .csproj > /app/.entry

# ---- test (optional target: docker build --target test .) -----------------------------------
FROM build AS test
ARG TEST_PROJECT=
RUN --mount=type=cache,id=nuget,target=/root/.nuget/packages \
    if [ -n "$TEST_PROJECT" ]; then dotnet test "$TEST_PROJECT" -c Release; \
    else dotnet test -c Release; fi

# ---- EF Core migrations bundle (optional target: migrations) --------------------------------
# `ez dotnet deploy` runs it before starting the new version when MIGRATIONS=true. It reads the
# connection string the app itself reads (e.g. ConnectionStrings__Default from the env file).
FROM build AS migrations-build
ARG PROJECT
ARG EF_PROJECT=
ARG EF_VERSION=10.*
RUN --mount=type=cache,id=nuget,target=/root/.nuget/packages \
    dotnet tool install --global dotnet-ef --version "$EF_VERSION" \
    && /root/.dotnet/tools/dotnet-ef migrations bundle \
         --project "${EF_PROJECT:-$PROJECT}" --startup-project "$PROJECT" \
         --configuration Release -o /efbundle

FROM mcr.microsoft.com/dotnet/aspnet:${DOTNET_VERSION} AS migrations
WORKDIR /app
COPY --from=build /app .
COPY --from=migrations-build /efbundle /app/efbundle
USER $APP_UID
ENTRYPOINT ["/app/efbundle"]

# ---- runtime -------------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/aspnet:${DOTNET_VERSION} AS final
ARG TZ=Asia/Tehran
ENV TZ=${TZ} \
    ASPNETCORE_HTTP_PORTS=8080 \
    DOTNET_gcServer=0
# curl for the health check only; tzdata is in the base image.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app .
# Writable data lives in volumes owned by the app user (storage-<env>, mounted by the compose file ez generates).
RUN mkdir -p /app/data && chown $APP_UID /app/data
USER $APP_UID
EXPOSE 8080
# The app maps /healthz (app.MapHealthChecks("/healthz")). Workers without HTTP: set
# HEALTHCHECK NONE in compose (healthcheck: disable: true).
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS http://localhost:8080/healthz || exit 1
# The assembly name was recorded at publish time, so this file serves any project.
ENTRYPOINT ["sh", "-c", "exec dotnet \"$(cat /app/.entry).dll\""]
