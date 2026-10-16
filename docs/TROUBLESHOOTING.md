# Troubleshooting

Start with the logs: `./ez dotnet logs <app> <env>`, `./ez dotnet status <app> <env>`, and for the
shared services `docker logs nginx-pm|mssql|redis|seq`.

## Docker access

**`Cannot connect to Docker daemon`**: Docker isn't running (`sudo systemctl start docker`) or your
user isn't in the `docker` group (`sudo usermod -aG docker $USER`, then log in again). Deploys also
need sudo for `chown` of `storage-<env>` to the container's uid (1654).

## Shared services

**mssql exits right after starting.** Read `docker logs mssql`. SQL Server needs 2 GB of RAM, an
amd64 host, and an `MSSQL_SA_PASSWORD` that satisfies its policy (8+ characters, upper, lower,
digit); `ez shared deploy` generates one. `shared/mssql` must be writable by uid 10001.

**`network ... not found`.** Run `./ez shared deploy` once; it creates `SHARED_NETWORK_NAME`.

**Nginx Proxy Manager admin unreachable.** It listens on `127.0.0.1` only:
`ssh -L 81:127.0.0.1:81 <server>`, then http://localhost:81.

## Deploys

**`project not found at apps/<app>/src-<env>/...`**: `PROJECT` in `apps/<app>/env/app.env` must
be the `.csproj` path relative to the repository root.

**Build fails at `dotnet restore`.** Private NuGet feeds need a `nuget.config` in the repository and
credentials passed as build secrets; package sources must be reachable from the server (build mode)
or from CI (image mode).

**`Could not pull ...` (image mode).** Check `APP_IMAGE`, the tag (`--tag`), and the registry
login: `REGISTRY_HOST`, `REGISTRY_USER`, `REGISTRY_TOKEN` in `docker/docker.env` (for GHCR, a token
with `read:packages`).

**Migrations fail.** `ez` stops before switching versions, so the old version keeps serving. Run
`./ez dotnet migrate <app> <env>` to see the error. The bundle reads the same connection string as
the app (`ConnectionStrings__Default`). Migrations must stay compatible with the running version
until the switch (expand, then contract).

**Deploy rolled back.** The new version wasn't healthy within 180s; its last 60 log lines are
printed above the rollback message. See [HEALTH_CHECKS.md](HEALTH_CHECKS.md).

## The app

**`Login failed for user`**: `DB_PASSWORD` in `<env>.env` and the login drifted; deploying again
resets the login's password from the env file.

**Wrong client IP or `http` links behind the proxy**: call `app.UseForwardedHeaders()` with
`XForwardedFor | XForwardedProto` and clear `KnownIPNetworks`/`KnownProxies` (the proxy is on the
Docker network); see `example/src/Example.Api/Program.cs`.

**Times are off by hours**: containers run in `TZ=Asia/Tehran` by default (`TZ` build arg and
environment). Prefer `DateTimeOffset`/UTC in code.

**Files written by the app disappear on deploy**: only `/app/data` (`storage-<env>`) survives;
write uploads and generated files there.

## Getting help

Open an issue at https://github.com/Andromeda-Network/ez-docker-for-dotnet/issues with the
command, its output and `./ez --version`.
