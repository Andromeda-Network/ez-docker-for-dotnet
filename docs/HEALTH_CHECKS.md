# Health Check Monitoring

## Overview

Every container `ez` runs has a Docker health check, and `ez dotnet deploy` uses the app's to
decide whether a deploy worked: a new version that doesn't become healthy within 180 seconds is
**rolled back** and the deploy fails.

## The app: `/healthz`

`template/dotnet.Dockerfile` probes `http://localhost:8080/healthz` every 30s (5s timeout, 3
retries, 30s start period). Map it in the app:

```csharp
builder.Services.AddHealthChecks()
    .AddDbContextCheck<AppDbContext>();          // Microsoft.Extensions.Diagnostics.HealthChecks.EntityFrameworkCore
var app = builder.Build();
app.MapHealthChecks("/healthz");
```

Check what the app cannot run without (its database, Redis), not every dependency: a health check
that fails when a third-party API is down makes `ez` roll back a version that was fine.

Workers without HTTP: set `healthcheck: { disable: true }` on their service; `ez` then waits for
the container to be running instead.

## Shared services

| Service | Check | Interval / timeout / retries |
|---|---|---|
| nginx-pm | `curl -f http://localhost:80` | 30s / 10s / 5, start 30s |
| mssql | `sqlcmd -Q 'SELECT 1'` as sa | 30s / 10s / 10, start 60s |
| postgres | `pg_isready -U postgres` | 10s / 5s / 5 |
| redis | `redis-cli ping` (with the password) | 10s / 5s / 5 |

`ez dotnet deploy` checks that nginx-pm and the database server are running and healthy before it
touches the app (`check_containers`).

## Monitoring health status

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'          # (healthy) / (unhealthy) / (health: starting)
docker ps --filter health=unhealthy
docker inspect --format '{{json .State.Health}}' myapp_production | jq '.Log[-5:]'
./ez dotnet status myapp production                          # containers + deployed version
```

| Status | Meaning |
|---|---|
| `starting` | Inside the start period; failures don't count yet |
| `healthy` | The last check passed |
| `unhealthy` | `retries` consecutive checks failed |

## Automatic recovery

Containers use `restart: unless-stopped`. Docker restarts a container whose process exits; it does
**not** restart one that is merely unhealthy. A deploy is the one place `ez` acts on health (it
rolls back). For running containers, alert on `unhealthy` (Seq, Uptime Kuma, a cron on
`docker ps --filter health=unhealthy`) and investigate.

## Manual testing

```bash
docker exec myapp_production curl -fsS http://localhost:8080/healthz      # Healthy
curl -fsS http://localhost:8000/healthz                                    # test, through APP_PORT
```

## Troubleshooting

**Never becomes healthy.** Run the probe yourself (above). Typical causes: `/healthz` not mapped
(404), the app listening on another port (ASP.NET Core in the image listens on 8080 via
`ASPNETCORE_HTTP_PORTS`; don't override `ASPNETCORE_URLS`), or a failing dependency check such as
a wrong connection string; see `./ez dotnet logs myapp production`.

**Healthy but not working.** The check is too shallow; add the dependency checks above.

## CI/CD

`.github.example/workflows/release.yml` deploys with `ez dotnet deploy … --tag sha-<commit>`; the
deploy step fails when the health check does, so a red pipeline means the old version is still
serving.
