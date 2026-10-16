<div align="center">
  <h1>EZ Docker For .NET</h1>
  <p>easy to set up, robust and production ready environment for .NET (ASP.NET Core) apps using Docker, Docker Compose and bash script.</p>
  <p>currently these scripts are debian based and tested on ubuntu 22.04.3 live Server</p>
</div>

<!-- About the Project -->

## :star2: About

EZ Docker For .NET runs ASP.NET Core applications on a single Linux server with Docker and Docker
Compose. One command line, `ez`, sets up the server, runs the services every app shares (a reverse
proxy with Let's Encrypt, SQL Server or PostgreSQL, Redis, Seq for logs), and creates and deploys
each app to `dev`, `test`, `staging` and `production`. It's the .NET edition of
[EZ Docker For Laravel](https://github.com/MansourM/ez-docker-for-laravel), and keeps its shape:
the same commands, shared services, environments and both deploy modes.

```
CI: test + build image ──push──► registry ──pull──► server: ./ez dotnet deploy <app> production --tag sha-…
                                                       │
nginx-pm (80/443, Let's Encrypt) ──► <app>_production :8080 ─┐
                                    <app>_staging    :8080 ─┼─ mssql | postgres, redis, seq
                                    <app>_test       :8080 ─┘   (one Docker network)
```

**What a deploy does** (`./ez dotnet deploy <app> <env>`):

1. builds the image on the server from git (**build mode**), or pulls the one CI built and tested (**image mode**, `--tag`);
2. creates the environment's own database and login, if missing;
3. runs the EF Core migrations bundle (`MIGRATIONS=true`), after an optional backup command; if either fails, the running version is left alone;
4. starts the new version and waits for its health check (`/healthz`);
5. if it isn't healthy, **rolls back** to the previous version and fails.

<!-- Security Features -->

## :shield: Security Features

- **Input validation**: app names, environments, project paths, image tags, Git URLs and SQL identifiers are validated before use
- **No passwords on command lines**: database passwords reach `sqlcmd`/`psql` through the environment, never `argv`
- **Least privilege**: each app environment gets its own database login; apps never see the `sa`/`postgres` password or the registry token
- **Hardened images**: Microsoft's `aspnet` runtime (no SDK), non-root user (uid 1654), no secrets baked in
- **Pinned versions**: every shared service, with health checks
- **Admin UIs on loopback only**: Nginx Proxy Manager, Seq and Portainer are reached through an SSH tunnel
- **Access control**: Docker group membership (no root required, except `sudo` for deploys' `chown`)

See [SECURITY.md](SECURITY.md).

<!-- Getting Started -->

## :toolbox: Getting Started

### Platform Requirements

- **Operating System**: Debian-based Linux (tested on Ubuntu 22.04.3 LTS)
- **Shell**: Bash 4.2+
- **Docker**: Docker Engine 20.10+ and Docker Compose V2
- **SQL Server** (the default database) needs an **amd64** host with 2 GB+ of RAM; use `DB_ENGINE=postgres` on arm64

**Windows/macOS users:** use a Linux server or VM (Windows: WSL2 with Ubuntu).

### Prerequisites

**Docker Access Setup:**

```bash
sudo usermod -aG docker $USER   # Option 1 (recommended): docker group, then log in again
sudo ./ez <command>             # Option 2: run with sudo
```

Deploys `chown` each environment's storage to the container's user, so run `ez dotnet deploy` with `sudo`.

### Installation Steps

1. Clone the repository:
   ```bash
   git clone https://github.com/Andromeda-Network/ez-docker-for-dotnet.git && cd ez-docker-for-dotnet
   ```

2. Install Docker engine (Optional, only if not installed already):
   ```bash
   ./ez docker install
   ```

3. Deploy your shared containers. The first run asks a few questions and writes `docker/docker.env`, with generated passwords:
   ```bash
   ./ez shared deploy
   ```

4. Initialize your .NET app (project path, .NET version, deploy mode, environments):
   ```bash
   ./ez dotnet new
   ```
   Then put the app's settings and secrets in `apps/<app>/env/<env>.env`. .NET reads nested keys
   with `__` (e.g. `Payments__ApiKey`); the connection string is already there.

5. Deploy your .NET app:
   ```bash
   sudo ./ez dotnet deploy {app_name} {environment}
   ```

## :tada: :tada: :tada:
* **`dev` and `test` run on `<your_ip_address>:<APP_PORT>`.** `dev` runs `dotnet watch` on the live checkout in `apps/<app>/src-dev`.
* **`staging` and `production` aren't exposed directly.** Add a proxy host in Nginx Proxy Manager for your domain, forwarding to `<app>_<env>`, port `8080`, with a Let's Encrypt certificate.

## :package: Your app repository

1. **Docker files:** copy `template/dotnet.Dockerfile` and `template/.dockerignore` to the repository root, next to the `.sln`/`.slnx`.
2. **A health check:**
   ```csharp
   builder.Services.AddHealthChecks();   // + .AddDbContextCheck<AppDbContext>() …
   app.MapHealthChecks("/healthz");
   ```
3. **Behind the proxy:** call `app.UseForwardedHeaders()` (see [`example/`](example/src/Example.Api/Program.cs)).
4. **Configuration:** read everything from configuration (`ConnectionStrings:Default`, `Section:Key`), never from files in the image.
5. **Writable files:** write only under `/app/data`, the environment's `storage-<env>` volume.
6. **EF Core migrations (optional):** set `MIGRATIONS=true` (and `EF_PROJECT` if the DbContext lives elsewhere). The Dockerfile's `migrations` stage builds a bundle that `ez` runs before each switch.

```bash
docker build -f dotnet.Dockerfile --build-arg PROJECT=src/MyApp/MyApp.csproj -t myapp .
docker build -f dotnet.Dockerfile --build-arg PROJECT=src/MyApp/MyApp.csproj --target test .   # tests, inside the build
```

## :gear: CI/CD (GitHub Actions)

Examples are in `.github.example/workflows`. Copy them to your app repository's `.github/workflows`.

- **`ci.yml`**: build and test every push and pull request, and check that the image builds.
- **`release.yml`**: on `staging` and `main`, run the tests inside the image, then push it and its migrations bundle to GitHub Container Registry (`sha-<commit>` tags). It then deploys over SSH with `./ez dotnet deploy <app> <env> --tag sha-<commit>`.
  - **Repository variables:** `APP_NAME`, `PROJECT`, `MIGRATIONS`, `EZ_DIR`.
  - **Environments:** `staging` and `production`, each with secrets `SSH_HOST`, `SSH_USER`, `SSH_KEY` (and `SSH_PORT`). Add required reviewers to `production` to approve its deploys.

For image mode, set `DEPLOY_MODE=image` and `APP_IMAGE=ghcr.io/<org>/<app>:latest` in the app's
`env/app.env`. Set `REGISTRY_USER` and `REGISTRY_TOKEN` in `docker/docker.env`; for GitHub, the
token needs `read:packages`. Rollback is then `./ez dotnet rollback <app> <env> <tag>`.

## :bulb: Additional Info
Nginx Proxy Manager default login information (change it on first login). The admin UI listens
on `127.0.0.1` only: `ssh -L 81:127.0.0.1:81 <server>`, then http://localhost:81.

| Username            | Password  |
|---------------------|-----------|
| admin@example.com   | changeme  |

**Logs and errors:** `./ez dotnet logs <app> <env>`. For searchable logs and errors across apps, keep
`seq` in `SHARED_PROFILES` and send logs to `http://seq:5341` (e.g. `Seq.Extensions.Logging`:
`builder.Logging.AddSeq(builder.Configuration.GetSection("Seq"))`). Its UI: `ssh -L 5380:127.0.0.1:5380 <server>`.

<!-- Other Commands -->

## :eyes: Other Commands

| Command | Description |
|---|---|
| `./ez --help` | Shows all commands |
| `./ez docker install` | Adds the Docker repository to APT sources and then installs the Docker engine. |
| `./ez docker uninstall` | Uninstalls the Docker engine. |
| `./ez docker remove` | Removes all images, containers, and volumes. (You have to delete any edited configuration files manually.) |
| `./ez shared deploy` | Runs the shared services: Nginx Proxy Manager and Redis, the database (`DB_ENGINE`) and the optional ones in `SHARED_PROFILES` (Seq, Portainer). |
| `./ez shared start\|stop\|restart\|down` | Starts, stops, restarts or removes the shared containers. |
| `./ez dotnet new` | Sets up a new .NET app in `apps/<app>`. |
| `./ez dotnet deploy <app> <env> [--tag TAG]` | Builds (or pulls `TAG`), creates the database, migrates, starts, health-checks, rolls back if unhealthy. |
| `./ez dotnet start\|stop\|restart <app> <env>` | Starts, stops or restarts the app's container (`--update`: pull the source first, dev). |
| `./ez dotnet down <app> <env>` | Removes the environment's containers (its storage stays). |
| `./ez dotnet logs <app> <env>` | Follows the app's logs. |
| `./ez dotnet status <app> <env>` | Shows the containers and the deployed version. |
| `./ez dotnet migrate <app> <env>` | Runs the EF Core migrations bundle. |
| `./ez dotnet rollback <app> <env> <tag>` | Image mode: redeploys an earlier tag. |

**Note:** If you haven't added your user to the docker group, prefix commands with `sudo`.

## :hammer_and_wrench: .NET Version

Each app picks its own .NET version: `ez dotnet new` stores `DOTNET_VERSION` in `apps/<app>/env/app.env`,
and `dotnet.Dockerfile` builds on `mcr.microsoft.com/dotnet/sdk:<version>` and runs on `aspnet:<version>`.

- **Supported:** `8.0`, `9.0`, `10.0`
- **Default:** `10.0`

Native dependencies (e.g. `libgdiplus`, fonts for PDF generation) go in the Dockerfile's final
stage, as an `apt-get install` next to `curl`.

<!-- Health Check Monitoring -->

## :heartbeat: Health Check Monitoring

| Service | Health Check Method | Interval | Timeout | Retries | Start Period |
|---------|-------------------|----------|---------|---------|--------------|
| **Your app** | `curl http://localhost:8080/healthz` | 30s | 5s | 3 | 30s |
| **Nginx Proxy Manager** | HTTP request to localhost:80 | 30s | 10s | 5 | 30s |
| **SQL Server** | `sqlcmd -Q 'SELECT 1'` | 30s | 10s | 10 | 60s |
| **PostgreSQL** | `pg_isready` | 10s | 5s | 5 | – |
| **Redis** | `redis-cli ping` | 10s | 5s | 5 | – |

```bash
docker ps --format "table {{.Names}}\t{{.Status}}"
```

See [docs/HEALTH_CHECKS.md](docs/HEALTH_CHECKS.md).

<!-- Roadmap -->

## :compass: TODOs

- [ ] zero-downtime deploys: start the new version next to the old one and switch only once it is healthy. Today a deploy replaces the container first, so a version that fails its health check is down until the rollback (~1.5 min with the default check timings)
- [ ] add flag to use default input instead of prompting the user (`ez dotnet new -d`)
- [ ] changing GIT_URL in app.env has no effect, will still pull from previous repo
- [ ] GitLab CI example for app repositories
- [ ] backups: a `PRE_MIGRATION_COMMAND` example and a scheduled database backup
- [ ] better handling of unused/dangling images (`docker image prune` after deploys)
- [ ] mark project as production ready when 1 month of testing in production is done.

<!-- Troubleshooting -->

## :wrench: Troubleshooting

**Docker Permission Issues**
```bash
sudo usermod -aG docker $USER && newgrp docker
```

**Database Connection Problems**
- Check `ConnectionStrings__Default` and `DB_*` in `apps/{app_name}/env/{environment}.env`; deploying again resets the login's password
- Ensure the database server is healthy: `docker ps | grep mssql`

**Deploy Rolled Back**
- The new version wasn't healthy within 180s; its last log lines are printed. `./ez dotnet logs {app_name} {environment}`

**Input Validation Errors**
- App names: Alphanumeric, hyphens, underscores only (max 64 chars)
- Environments: `dev`, `test`, `staging`, or `production` only
- `PROJECT`: a relative path to a `.csproj`

For complete troubleshooting guide, see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

<!-- Development -->

## :wrench: Developing ez

`ez` is generated by [Bashly](https://bashly.dev) from `src/`, so never edit it directly. Edit `src/`, then:

```bash
gem install bashly -v 1.3.8
LC_ALL=en_US.UTF-8 bashly generate    # regenerates ./ez
bash tests/run.sh                     # the flows, against a stub docker
```

CI checks that `ez` matches `src/`, runs shellcheck and the flow tests, and builds and runs the
example app with the template Dockerfile. See [docs/bashly.md](docs/bashly.md).

<!-- Contributing -->

## :wave: Contributing

Contributions are always welcome! Feel free to fork the project and submit a pull request.

<!-- License -->

## :warning: License

This project is licensed under the GNU GPL V2 License, as is EZ Docker For Laravel, which it is forked from.

<!-- Documentation -->

## :books: Documentation

- **[Documentation Index](docs/README.md)**: complete documentation guide
- **[Security Policy](SECURITY.md)**: security features and vulnerability reporting
- **[Troubleshooting](docs/TROUBLESHOOTING.md)**: detailed problem-solving guide
- **[Health Checks](docs/HEALTH_CHECKS.md)**: service monitoring and recovery

<!-- Acknowledgments -->

## :gem: Acknowledgements

- [EZ Docker For Laravel](https://github.com/MansourM/ez-docker-for-laravel) by Seyed Mansour Mirbehbahani, which this is forked from
- [Awesome Readme Template](https://github.com/Louis3797/awesome-readme-template)
- [Microsoft: containerize a .NET app](https://learn.microsoft.com/dotnet/core/docker/build-container)
