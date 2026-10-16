# docker compose for one environment of one app. Each environment is its own compose project
# (<app>_<env>), so a command for test can never touch production's containers.
#
# Needs: app_dir, merged_env_path (merge_app_envs) and the loaded env (load_app_envs).
dotnet_compose() {
  local file="$app_dir/env/generated/compose.${args[APP_ENV]}.yml" files project
  generate_compose "$file" "$(ez_image_tag)"
  files=(-f "$file")
  if [[ -f "$app_dir/compose.override.yml" ]]; then
    files+=(-f "$app_dir/compose.override.yml")
  fi
  project=$(echo "${args[APP_NAME]}_${args[APP_ENV]}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_\n-' '_')
  # --project-directory: relative paths in compose.override.yml resolve against apps/<app>.
  docker compose -p "$project" --project-directory "$app_dir" "${files[@]}" --env-file "$merged_env_path" "$@"
}

# Image mode: the tag to run. EZ_TAG while a deploy or rollback sets it, else the deployed one,
# else APP_IMAGE's own tag.
ez_image_tag() {
  if [[ -n "${EZ_TAG:-}" ]]; then echo "$EZ_TAG"; return; fi
  local deployed
  deployed=$(read_deployed_tag "${args[APP_NAME]}" "${args[APP_ENV]}")
  if [[ -n "$deployed" && "$deployed" != git-* ]]; then echo "$deployed"; else image_tag "${APP_IMAGE:-x:latest}"; fi
}

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
  # dev runs live source and test builds the tree it is testing: image mode is for the
  # deployed environments, so an image-mode app still builds these two from git.
  if [[ "$DEPLOY_MODE" == "image" && ( "${args[APP_ENV]}" == "dev" || "${args[APP_ENV]}" == "test" ) ]]; then
    DEPLOY_MODE=build
    IMAGE_MODE_APP=1
  fi
  validate_services
}
