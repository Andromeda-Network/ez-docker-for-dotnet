#!/usr/bin/env bash
# Exercises ez's flows without Docker: a stub `docker` (tests/stub/docker) records every call.
# Run from the repository root: bash tests/run.sh   (bash >= 4.2, like ez itself)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export PATH="$ROOT/tests/stub:$PATH" STUB_LOG="$WORK/docker.log" STUB_STATE="$WORK/state"
# On a server ez runs with sudo and gives storage to the image's uid 1654; here, to ourselves.
export IMAGE_USER_ID IMAGE_GROUP_ID; IMAGE_USER_ID=$(id -u); IMAGE_GROUP_ID=$(id -g)
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

echo "new app"
me=$(id -un)
printf 'shop\n%s\nhttps://example.com/shop.git\nsrc/Shop/Shop.csproj\n10.0\nimage\nghcr.io/acme/shop:latest\ntrue\nno\n8000\nyes\nstaging\nshop_staging\nshop_staging_user\n\nyes\nmain\nshop_production\nshop_production_user\n\n' "$me" \
  | $EZ dotnet new >/dev/null 2>&1 || true
# `new` asks for test's branch/db/user/password and port; feed defaults by re-running per env if needed
[[ -f apps/shop/env/app.env ]] || fail "apps/shop/env/app.env"
grep -q '^DEPLOY_MODE=image$' apps/shop/env/app.env || fail "deploy mode"
ok "apps/shop created (image mode)"
for f in dotnet.Dockerfile compose-dotnet.yml compose-dotnet-image.yml common-dotnet.yml .dockerignore; do
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
expect_log 'compose -p shop_production -f apps/shop/compose-dotnet-image.yml --profile production .* pull dotnet-production' "image pulled before anything stops"
expect_log 'compose -p shop_production .*--profile migrate run --rm migrate' "migrations run before the switch"
expect_log 'compose -p shop_production .* up -d --no-build dotnet-production' "started"
expect_log 'inspect -f .* shop_production$' "the app's own container is health-checked"
grep -q 'APP_IMAGE=ghcr.io/acme/shop:sha-aaa' "$STUB_STATE" || fail "started with sha-aaa"
ok "started ghcr.io/acme/shop:sha-aaa"
[[ "$(cat apps/shop/env/generated/production.deployed)" == sha-aaa ]] || fail "deployed tag recorded"
ok "deployed tag recorded"
! grep -q 'MSSQL_SA_PASSWORD\|REGISTRY_TOKEN' apps/shop/env/generated/production.env || fail "secrets masked"
ok "sa password and registry token are not in the app's environment"

echo "unhealthy deploy rolls back"
: >"$STUB_LOG"
if STUB_HEALTH_AFTER=sha-aaa $EZ dotnet deploy shop production --tag sha-bbb >/dev/null 2>&1; then fail "unhealthy deploy should fail"; fi
grep -q 'APP_IMAGE=ghcr.io/acme/shop:sha-aaa' "$STUB_STATE" || fail "rolled back to sha-aaa"
ok "unhealthy sha-bbb rolled back to sha-aaa, deploy failed"
[[ "$(cat apps/shop/env/generated/production.deployed)" == sha-aaa ]] || fail "tag unchanged"
ok "deployed tag still sha-aaa"

echo "rollback command"
$EZ dotnet rollback shop production sha-aaa >/dev/null 2>&1 || fail "rollback"
grep -q 'APP_IMAGE=ghcr.io/acme/shop:sha-aaa' "$STUB_STATE" || fail "rollback image"
ok "ez dotnet rollback redeploys a tag"

echo "deploy (build mode) from git"
src=$(mktemp -d)
cp -R "$ROOT/example/." "$src/"
git -C "$src" init -q -b test && git -C "$src" add -A && git -C "$src" -c user.email=t@t -c user.name=t commit -qm example
mkdir -p apps/api/env/generated
cp template/dotnet.Dockerfile template/.dockerignore template/common-dotnet.yml template/compose-dotnet.yml template/compose-dotnet-image.yml apps/api/
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
expect_log 'compose -p api_test -f apps/api/compose-dotnet.yml --profile test .* build dotnet-test' "built on this host"
expect_log 'compose -p api_test .* up -d --no-build dotnet-test' "started"
grep -q '^git-' apps/api/env/generated/test.deployed || fail "commit recorded"
ok "deployed commit recorded"
: >"$STUB_LOG"
if STUB_HAS_IMAGE=1 STUB_HEALTH=unhealthy $EZ dotnet deploy api test >/dev/null 2>&1; then fail "unhealthy build should fail"; fi
expect_log 'tag api:test api:test-previous' "running image kept as api:test-previous"
expect_log 'tag api:test-previous api:test' "unhealthy build swapped back to the previous one"
if $EZ dotnet deploy api test --tag x >/dev/null 2>&1; then fail "--tag accepted in build mode"; fi
ok "--tag refused in build mode"

echo "input validation"
if $EZ dotnet deploy 'bad;name' production >/dev/null 2>&1; then fail "bad app name accepted"; fi
ok "bad app name refused"
if $EZ dotnet deploy shop production --tag 'x y' >/dev/null 2>&1; then fail "bad tag accepted"; fi
ok "bad tag refused"

echo "$pass checks passed"
