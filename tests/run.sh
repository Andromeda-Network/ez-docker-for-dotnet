#!/usr/bin/env bash
# Exercises ez's flows without Docker: a stub `docker` (tests/stub/docker) records every call.
# Run from the repository root: bash tests/run.sh   (bash >= 4.2, like ez itself)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export PATH="$ROOT/tests/stub:$PATH" STUB_LOG="$WORK/docker.log" STUB_STATE="$WORK/state"
# On a server ez runs with sudo and gives storage to the image's uid 1654; here, to ourselves.
export IMAGE_USER_ID IMAGE_GROUP_ID MSSQL_UID MSSQL_GID
IMAGE_USER_ID=$(id -u); IMAGE_GROUP_ID=$(id -g); MSSQL_UID=$(id -u); MSSQL_GID=$(id -g)
# Health waits poll without sleeping.
export EZ_POLL_SECONDS=0 EZ_SETTLE_SECONDS=0
# EZ_TEST_OUT: keep the compose files ez generates, for CI to validate with a real docker.
# The app folders are copied along (env files, override) and the paths rewritten to the copy.
save_compose() {
  if [[ -z "${EZ_TEST_OUT:-}" ]]; then return; fi
  local app
  for app in "$WORK"/apps/*/; do
    app=$(basename "$app")
    mkdir -p "$EZ_TEST_OUT/work/apps/$app"
    cp -R "$WORK/apps/$app/env" "$EZ_TEST_OUT/work/apps/$app/"
    if [[ -f "$WORK/apps/$app/compose.override.yml" ]]; then cp "$WORK/apps/$app/compose.override.yml" "$EZ_TEST_OUT/work/apps/$app/"; fi
  done
  sed "s|$WORK|$EZ_TEST_OUT/work|g" "$1" >"$EZ_TEST_OUT/$2.yml"
}
pass=0
ok()   { echo "  ok   $*"; pass=$((pass + 1)); }
fail() { echo "  FAIL $*"; echo "--- docker calls:"; cat "$STUB_LOG"; exit 1; }
expect_log() { grep -qE -- "$1" "$STUB_LOG" || fail "$2 (no docker call matching: $1)"; ok "$2"; }

cp -R "$ROOT/ez" "$ROOT/template" "$ROOT/docker" "$WORK/"
mkdir -p "$WORK/apps"
cd "$WORK"
EZ="bash ./ez"

echo "shared services"
printf 'ez-net\n81\nmssql\nseq\n' | $EZ shared deploy >/dev/null
grep -q '^DB_ENGINE=mssql$' docker/docker.env && grep -q '^MSSQL_SA_PASSWORD=.\{24\}Aa1$' docker/docker.env || fail "docker.env"
ok "docker.env created with a generated sa password"
expect_log 'compose -p ez-shared .*--profile mssql --profile seq up -d' "shared compose starts mssql and seq"
[[ -d shared/mssql ]] || fail "shared/mssql created before SQL Server starts"
ok "shared/mssql created for SQL Server's user"

echo "new app"
me=$(id -un)
printf 'shop\n%s\nhttps://example.com/shop.git\nsrc/Shop/Shop.csproj\n10.0\nimage\nghcr.io/acme/shop:latest\ntrue\nno\n8000\nyes\nstaging\nshop_staging\nshop_staging_user\n\nyes\nmain\nshop_production\nshop_production_user\n\n' "$me" \
  | $EZ dotnet new >/dev/null 2>&1 || true
# `new` asks for test's branch/db/user/password and port; feed defaults by re-running per env if needed
[[ -f apps/shop/env/app.env ]] || fail "apps/shop/env/app.env"
grep -q '^DEPLOY_MODE=image$' apps/shop/env/app.env || fail "deploy mode"
ok "apps/shop created (image mode)"
for f in dotnet.Dockerfile .dockerignore; do
  [[ -f "apps/shop/$f" ]] || fail "template $f copied"
done
ok "templates copied"
[[ -f apps/shop/env/production.env ]] || fail "production.env"
grep -q '^ASPNETCORE_ENVIRONMENT=Production$' apps/shop/env/production.env || fail "aspnet env"
grep -q '^ConnectionStrings__Default=Server=mssql;Database=shop_production;User Id=shop_production_user;' apps/shop/env/production.env || fail "connection string"
ok "production.env has the connection string for its own login"

echo "deploy (image mode) with --tag"
: >"$STUB_LOG"
$EZ dotnet deploy shop production --tag sha-aaa >/dev/null 2>&1 || fail "deploy sha-aaa"
expect_log 'exec -i -e SQLCMDPASSWORD -e DB -e USR -e PWD_ mssql .*sqlcmd' "database and login created through sqlcmd"
if grep -q 'PASSWORD=' "$STUB_LOG"; then fail "a password is on the docker command line"; fi
ok "no password on any docker command line"
expect_log 'compose -p shop_production --project-directory apps/shop -f apps/shop/env/generated/compose.production.yml .* pull web' "image pulled before anything stops"
grep -q '^SERVICES=web$' apps/shop/env/app.env || fail "SERVICES=web"
save_compose apps/shop/env/generated/compose.production.yml shop-production-image
expect_log 'compose -p shop_production .*--profile migrate run --rm migrate' "migrations run before the switch"
expect_log 'compose -p shop_production .* up -d --no-build --remove-orphans web' "started"
expect_log 'inspect -f .* shop_production$' "the app's own container is health-checked"
grep -q 'ghcr.io/acme/shop:sha-aaa"' "$STUB_STATE" || fail "started with sha-aaa"
ok "started ghcr.io/acme/shop:sha-aaa"
[[ "$(cat apps/shop/env/generated/production.deployed)" == sha-aaa ]] || fail "deployed tag recorded"
ok "deployed tag recorded"
! grep -q 'MSSQL_SA_PASSWORD\|REGISTRY_TOKEN' apps/shop/env/generated/production.env || fail "secrets masked"
ok "sa password and registry token are not in the app's environment"

echo "unhealthy deploy rolls back"
: >"$STUB_LOG"
if STUB_HEALTH_AFTER=sha-aaa $EZ dotnet deploy shop production --tag sha-bbb >/dev/null 2>&1; then fail "unhealthy deploy should fail"; fi
grep -q 'ghcr.io/acme/shop:sha-aaa"' "$STUB_STATE" || fail "rolled back to sha-aaa"
ok "unhealthy sha-bbb rolled back to sha-aaa, deploy failed"
[[ "$(cat apps/shop/env/generated/production.deployed)" == sha-aaa ]] || fail "tag unchanged"
ok "deployed tag still sha-aaa"

echo "image-mode app: test still builds from source"
: >"$STUB_LOG"
src2=$(mktemp -d); cp -R "$ROOT/example/." "$src2/"
git -C "$src2" init -q -b test && git -C "$src2" add -A && git -C "$src2" -c user.email=t@t -c user.name=t commit -qm example
sed -i.bak "s|^GIT_URL=.*|GIT_URL=$src2|; s|^PROJECT=.*|PROJECT=src/Example.Api/Example.Api.csproj|" apps/shop/env/app.env
printf 'GIT_BRANCH=test\nAPP_ENV=test\nASPNETCORE_ENVIRONMENT=Test\nAPP_PORT=8002\nDB_DATABASE=\n' >apps/shop/env/test.env
STUB_HEALTH=healthy $EZ dotnet deploy shop test >/dev/null 2>&1 || fail "image-mode app deploying test"
expect_log 'compose -p shop_test .* build web' "test built from source although the app is in image mode"
grep -q 'context: ".*/apps/shop/src-test"' apps/shop/env/generated/compose.test.yml || fail "test's build context"
ok "test's build context is its own checkout"

echo "rollback command"
$EZ dotnet rollback shop production sha-aaa >/dev/null 2>&1 || fail "rollback"
grep -q 'ghcr.io/acme/shop:sha-aaa"' "$STUB_STATE" || fail "rollback image"
ok "ez dotnet rollback redeploys a tag"

echo "deploy (build mode) from git"
src=$(mktemp -d)
cp -R "$ROOT/example/." "$src/"
git -C "$src" init -q -b test && git -C "$src" add -A && git -C "$src" -c user.email=t@t -c user.name=t commit -qm example
mkdir -p apps/api/env/generated
cp template/dotnet.Dockerfile template/.dockerignore apps/api/
cat >apps/api/env/app.env <<EOL
APP_NAME=api
GIT_URL=$src
PROJECT=src/Example.Api/Example.Api.csproj
DEPLOY_MODE=build
MIGRATIONS=false
OWNER_USER_NAME=$(id -un)
OWNER_GROUP_NAME=$(id -gn)
EOL
printf 'GIT_BRANCH=test\nAPP_ENV=test\nASPNETCORE_ENVIRONMENT=Test\nAPP_PORT=8000\nDB_DATABASE=\n' >apps/api/env/test.env
: >"$STUB_LOG"
$EZ dotnet deploy api test >/dev/null 2>&1 || fail "build-mode deploy"
[[ -f apps/api/src-test/src/Example.Api/Example.Api.csproj ]] || fail "clone"
ok "cloned GIT_URL's test branch into apps/api/src-test"
[[ -f apps/api/src-test/.dockerignore ]] || fail ".dockerignore"
ok ".dockerignore added to the build context"
expect_log 'compose -p api_test .* build web' "built on this host"
save_compose apps/api/env/generated/compose.test.yml api-test-build
expect_log 'compose -p api_test .* up -d --no-build --remove-orphans web' "started"
grep -q '^git-' apps/api/env/generated/test.deployed || fail "commit recorded"
ok "deployed commit recorded"
: >"$STUB_LOG"
if STUB_HAS_IMAGE=1 STUB_HEALTH=unhealthy $EZ dotnet deploy api test >/dev/null 2>&1; then fail "unhealthy build should fail"; fi
expect_log 'tag api:test api:test-previous' "running image kept as api:test-previous"
expect_log 'tag api:test-previous api:test' "unhealthy build swapped back to the previous one"
if $EZ dotnet deploy api test --tag x >/dev/null 2>&1; then fail "--tag accepted in build mode"; fi
ok "--tag refused in build mode"

echo "multi-service app (web + worker + uploader)"
src3=$(mktemp -d); mkdir -p "$src3/app"; cp -R "$ROOT/example/." "$src3/app/"
printf 'FROM scratch\n' >"$src3/app/uploader.Dockerfile"
git -C "$src3" init -q -b main && git -C "$src3" add -A && git -C "$src3" -c user.email=t@t -c user.name=t commit -qm multi
mkdir -p apps/multi/env/generated
cp template/dotnet.Dockerfile template/.dockerignore apps/multi/
cat >apps/multi/env/app.env <<EOL
APP_NAME=multi
SERVICES=web worker uploader
GIT_URL=$src3
PROJECT=src/Example.Api/Example.Api.csproj
WEB_CONTEXT=app
WEB_HEALTH=/healthz
WORKER_PROJECT=src/Example.Api/Example.Api.csproj
WORKER_CONTEXT=app
WORKER_HEALTH=none
UPLOADER_CONTEXT=app
UPLOADER_DOCKERFILE=uploader.Dockerfile
UPLOADER_PROJECT=src/Example.Api/Example.Api.csproj
UPLOADER_PORT=9091
UPLOADER_HEALTH=/healthz
DEPLOY_MODE=image
APP_IMAGE=ghcr.io/acme/multi:latest
MIGRATIONS=false
OWNER_USER_NAME=$(id -un)
OWNER_GROUP_NAME=$(id -gn)
EOL
printf 'GIT_BRANCH=main\nAPP_ENV=staging\nASPNETCORE_ENVIRONMENT=Staging\nDB_DATABASE=\n' >apps/multi/env/staging.env
printf 'GIT_BRANCH=main\nAPP_ENV=test\nASPNETCORE_ENVIRONMENT=Test\nAPP_PORT=9090\nDB_DATABASE=\n' >apps/multi/env/test.env
printf 'services:\n  worker:\n    depends_on: [ web ]\n' >apps/multi/compose.override.yml

: >"$STUB_LOG"
$EZ dotnet deploy multi test >/dev/null 2>&1 || fail "multi-service build deploy"
gen=apps/multi/env/generated/compose.test.yml
save_compose "$gen" multi-test-build
for c in multi_test multi_test_worker multi_test_uploader; do grep -q "container_name: \"$c\"" "$gen" || fail "container $c"; done
ok "three containers: multi_test, multi_test_worker, multi_test_uploader"
grep -q 'ports: \[ "9090:8080" \]' "$gen" && grep -q 'ports: \[ "9091:8080" \]' "$gen" || fail "ports"
ok "web on APP_PORT, uploader on UPLOADER_PORT, worker unpublished"
grep -q 'dockerfile: ".*/apps/multi/src-test/app/uploader.Dockerfile"' "$gen" || fail "uploader's Dockerfile"
grep -q 'context: ".*/apps/multi/src-test/app"' "$gen" || fail "subfolder context"
ok "per-service context and Dockerfile"
expect_log 'compose -p multi_test .*-f apps/multi/compose.override.yml .* build web worker uploader' "every service built, with the app's override"
expect_log 'compose -p multi_test .* up -d --no-build --remove-orphans web worker uploader' "every service started together"
grep -q 'curl .*http://172.18.0.9:8080/healthz' "$STUB_LOG" || fail "HTTP probe"
ok "/healthz probed from the host for services with <SVC>_HEALTH=/path"

: >"$STUB_LOG"
$EZ dotnet deploy multi staging --tag v1 >/dev/null 2>&1 || fail "multi-service image deploy v1"
gen=apps/multi/env/generated/compose.staging.yml
save_compose "$gen" multi-staging-image
grep -q 'image: "ghcr.io/acme/multi:v1"' "$gen" && grep -q 'image: "ghcr.io/acme/multi-worker:v1"' "$gen" && grep -q 'image: "ghcr.io/acme/multi-uploader:v1"' "$gen" || fail "registry names"
ok "image mode pulls <APP_IMAGE>, -worker and -uploader at one tag"
expect_log 'compose -p multi_staging .* pull web worker uploader' "every image pulled before anything stops"

: >"$STUB_LOG"
if STUB_DOWN_SERVICE=worker $EZ dotnet deploy multi staging --tag v2 >/dev/null 2>&1; then fail "a failing worker should fail the deploy"; fi
for i in multi multi-worker multi-uploader; do grep -q "ghcr.io/acme/$i:v1\"" "$STUB_STATE" || fail "$i back on v1"; done
if grep -q ':v2"' "$STUB_STATE"; then fail "a service left on v2"; fi
ok "the worker failed, so all three services rolled back to v1"
[[ "$(cat apps/multi/env/generated/staging.deployed)" == v1 ]] || fail "multi tag unchanged"
ok "deployed tag still v1"

sed -i.bak 's/^SERVICES=.*/SERVICES=web Bad_Name/' apps/multi/env/app.env
if $EZ dotnet status multi staging >/dev/null 2>&1; then fail "bad service name accepted"; fi
ok "invalid service name refused"
sed -i.bak 's/^SERVICES=.*/SERVICES=web extra/' apps/multi/env/app.env
if $EZ dotnet status multi staging >/dev/null 2>&1; then fail "service without project accepted"; fi
ok "a service without a project refused"

echo "input validation"
if $EZ dotnet deploy 'bad;name' production >/dev/null 2>&1; then fail "bad app name accepted"; fi
ok "bad app name refused"
if $EZ dotnet deploy shop production --tag 'x y' >/dev/null 2>&1; then fail "bad tag accepted"; fi
ok "bad tag refused"

echo "$pass checks passed"
