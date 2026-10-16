merge_envs() {
  if [ "$#" -lt 3 ]; then
    log_error "Usage: merge_env <output> <file1> <file2> [file3 ... fileN]"
    exit 1
  fi

  local output="$1"
  shift

  local merged_content=""

  for file in "$@"; do
    if [ ! -e "$file" ]; then
      log_error "$file does not exist!"
      exit 1
    fi

    # Sort, filter, and remove duplicates from merged content
    merged_content=$(sort -u -t '=' -k 1,1 "$file" <(printf "%s" "$merged_content") | grep -v '^$\|^\s*\#')
  done

  # Mask host-side plumbing out of the app's .env. These configure ez itself — the registry it
  # pulls from, the database superuser, the source repo — and the application has no use for any
  # of them; REGISTRY_TOKEN especially has no business inside an app's environment.
  # TODO improve this part
  # The shared services' own superuser passwords (SQL Server sa, Postgres, Redis, Seq) are ez's,
  # not the app's: each app gets its own database login (create_new_database_and_user).
  merged_content=$(echo "$merged_content" | grep -Ev '^(SHARED_NETWORK_NAME|SHARED_PROFILES|DB_ROOT_PASSWORD|MSSQL_SA_PASSWORD|POSTGRES_PASSWORD|SEQ_ADMIN_PASSWORD|GIT_URL|REGISTRY_HOST|REGISTRY_USER|REGISTRY_TOKEN)=')

  echo "$merged_content" > "$output"
}
