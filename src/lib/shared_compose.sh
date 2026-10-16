# docker compose for the shared services, with the optional ones in SHARED_PROFILES
# (docker/docker.env: e.g. "mssql seq") and the database in DB_ENGINE.
shared_compose() {
  local profiles=() p
  for p in ${DB_ENGINE:-mssql} ${SHARED_PROFILES:-}; do
    [[ "$p" == none ]] && continue
    profiles+=(--profile "$p")
  done
  docker compose -p ez-shared -f docker/compose-shared.yml --env-file docker/docker.env "${profiles[@]}" "$@"
}
