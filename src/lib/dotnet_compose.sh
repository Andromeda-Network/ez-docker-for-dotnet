# docker compose for one environment of one app. Each environment is its own compose project
# (<app>_<env>), so a command for test can never touch production's containers.
#
# Needs: app_dir, merged_env_path (merge_app_envs) and the loaded env (load_app_envs).
dotnet_compose() {
  local file="$app_dir/compose-dotnet.yml"
  if [[ "${DEPLOY_MODE:-build}" == "image" && "${args[APP_ENV]}" != "dev" && "${args[APP_ENV]}" != "test" ]]; then
    file="$app_dir/compose-dotnet-image.yml"
  fi
  local project
  project=$(echo "${args[APP_NAME]}_${args[APP_ENV]}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_\n-' '_')
  docker compose -p "$project" -f "$file" --profile "${args[APP_ENV]}" --env-file "$merged_env_path" "$@"
}

# The compose service and container of an environment.
dotnet_service() { echo "dotnet-${args[APP_ENV]}"; }
dotnet_container() { echo "${args[APP_NAME]}_${args[APP_ENV]}"; }

# Validate APP_NAME/APP_ENV, find the app, merge and load its environment.
prepare_app() {
  if ! validate_app_name "${args[APP_NAME]}"; then
    log_error "Invalid application name: ${args[APP_NAME]}"
    log_error "Application names must contain only letters, numbers, hyphens and underscores (64 at most)."
    exit 1
  fi
  if ! validate_environment "${args[APP_ENV]}"; then
    log_error "Invalid environment: ${args[APP_ENV]} (dev, test, staging or production)"
    exit 1
  fi

  app_dir="apps/${args[APP_NAME]}"
  if [[ ! -d "$app_dir" ]]; then
    log_error "Application directory not found: $app_dir"
    log_error "The application '${args[APP_NAME]}' has not been initialized. Create it first:"
    log_error "  ./ez dotnet new"
    exit 1
  fi
  if [[ ! -f "$app_dir/env/${args[APP_ENV]}.env" ]]; then
    log_error "No ${args[APP_ENV]} environment for ${args[APP_NAME]} ($app_dir/env/${args[APP_ENV]}.env)."
    exit 1
  fi

  merged_env_path=$(merge_app_envs "$app_dir" "${args[APP_ENV]}")
  load_app_envs "$app_dir" "${args[APP_ENV]}" >/dev/null
  DEPLOY_MODE="${DEPLOY_MODE:-build}"
  if [[ "$DEPLOY_MODE" != "build" && "$DEPLOY_MODE" != "image" ]]; then
    log_error "Invalid DEPLOY_MODE: '$DEPLOY_MODE' (expected 'build' or 'image') in $app_dir/env/app.env"
    exit 1
  fi
}
