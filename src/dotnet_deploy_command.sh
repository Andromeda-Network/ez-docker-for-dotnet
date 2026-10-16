#inspect_args

prepare_app

log_header "Preparing to deploy ${args[APP_NAME]} (.NET) in ${args[APP_ENV]} mode"

env_name="${args[APP_ENV]}"
service=$(dotnet_service)

if [[ "$DEPLOY_MODE" == "image" ]]; then
  # The image already contains the application, so this host needs no source or SDK; CI built
  # and tested it.
  if [[ "$env_name" == "dev" || "$env_name" == "test" ]]; then
    log_error "DEPLOY_MODE=image does not apply to $env_name."
    log_error "dev runs live source and test builds the tree it is testing; neither runs a fixed artifact."
    exit 1
  fi
  if [[ -z "$APP_IMAGE" ]]; then
    log_error "DEPLOY_MODE=image but APP_IMAGE is empty. Set it in $app_dir/env/app.env, e.g."
    log_error "  APP_IMAGE=ghcr.io/your-org/your-app:latest"
    exit 1
  fi
  if [[ -n "${args[--tag]}" ]]; then
    if ! validate_image_tag "${args[--tag]}"; then
      log_error "Invalid --tag: ${args[--tag]}"
      exit 1
    fi
    APP_IMAGE="$(image_name "$APP_IMAGE"):${args[--tag]}"
  fi
  MIGRATIONS_IMAGE="$(image_name "$APP_IMAGE")-migrations:$(image_tag "$APP_IMAGE")"
  export APP_IMAGE MIGRATIONS_IMAGE
  log_info "Image mode — deploying $APP_IMAGE (no source checkout, no build on this host)."
else
  if [[ -n "${args[--tag]}" ]]; then
    log_error "--tag is for DEPLOY_MODE=image; build mode builds GIT_BRANCH's head."
    exit 1
  fi
  if ! validate_project_path "$PROJECT"; then
    log_error "Set PROJECT in $app_dir/env/app.env to your .csproj, relative to the repository root."
    exit 1
  fi
  update_source_code
fi

containers=("nginx-pm")
if [[ "${DB_ENGINE:-mssql}" != "none" ]]; then
  containers+=("${DB_ENGINE:-mssql}")
fi
check_containers "${containers[@]}"

if [[ "${DB_ENGINE:-mssql}" != "none" && -n "$DB_DATABASE" ]]; then
  create_new_database_and_user "$DB_DATABASE" "$DB_USERNAME" "$DB_PASSWORD"
fi

# dev: `dotnet watch` on the live checkout, nothing to build, migrate or roll back.
if [[ "$env_name" == "dev" ]]; then
  chown -R "$OWNER_USER_NAME:$OWNER_GROUP_NAME" "$app_dir/src-dev"
  log_header "Running Docker Compose for ${args[APP_NAME]} dev"
  if ! dotnet_compose up -d "$service"; then
    log_error "Failed to start ${args[APP_NAME]} (dev). Logs: ./ez dotnet logs ${args[APP_NAME]} dev"
    exit 1
  fi
  log_success "Running $(dotnet_container): dotnet watch on $app_dir/src-dev, http://<your_ip>:$APP_PORT"
  exit 0
fi

# The data volume belongs to the image's app user (uid 1654 in Microsoft's .NET images), not the
# host's; it must exist with that owner before the container's first write.
storage_dir="$app_dir/storage-$env_name"
mkdir -p "$storage_dir"
if ! chown -R "${IMAGE_USER_ID:-1654}:${IMAGE_GROUP_ID:-1654}" "$storage_dir"; then
  log_error "Cannot give $storage_dir to the container's user (uid ${IMAGE_USER_ID:-1654}): run ez with sudo."
  exit 1
fi

previous_tag=$(read_deployed_tag "${args[APP_NAME]}" "$env_name")
container=$(dotnet_container)

log_header "Preparing the new version of ${args[APP_NAME]} ($env_name)"
if [[ "$DEPLOY_MODE" == "image" ]]; then
  registry_login "$REGISTRY_HOST" "$REGISTRY_USER" "$REGISTRY_TOKEN"
  # Pull first, so a registry or tag problem fails before the running container is touched.
  if ! dotnet_compose pull "$service"; then
    log_error "Could not pull $APP_IMAGE."
    exit 1
  fi
  if [[ "${MIGRATIONS:-false}" == "true" ]] && ! dotnet_compose --profile migrate pull migrate; then
    log_error "Could not pull $MIGRATIONS_IMAGE (CI publishes it when MIGRATIONS=true)."
    exit 1
  fi
  new_tag=$(image_tag "$APP_IMAGE")
else
  # Keep the running image as <app>:<env>-previous, so an unhealthy build can be swapped back.
  if docker image inspect "${args[APP_NAME]}:$env_name" >/dev/null 2>&1; then
    docker tag "${args[APP_NAME]}:$env_name" "${args[APP_NAME]}:$env_name-previous"
  fi
  if ! dotnet_compose build "$service"; then
    log_error "Build failed; the running version was not touched."
    exit 1
  fi
  if [[ "${MIGRATIONS:-false}" == "true" ]] && ! dotnet_compose --profile migrate build migrate; then
    log_error "Building the migrations bundle failed; the running version was not touched."
    exit 1
  fi
  new_tag="git-$(git -C "$app_dir/src-$env_name" rev-parse --short HEAD)"
fi

if [[ "${MIGRATIONS:-false}" == "true" ]]; then
  if [[ -n "${PRE_MIGRATION_COMMAND:-}" ]]; then
    log_info "Pre-migration command (e.g. a database backup): $PRE_MIGRATION_COMMAND"
    if ! bash -c "$PRE_MIGRATION_COMMAND"; then
      log_error "Pre-migration command failed; nothing was migrated or restarted."
      exit 1
    fi
  fi
  log_info "Applying EF Core migrations"
  if ! dotnet_compose --profile migrate run --rm migrate; then
    log_error "Migrations failed; the running version was not touched."
    exit 1
  fi
fi

log_header "Running Docker Compose for ${args[APP_NAME]} $env_name"
if ! dotnet_compose up -d --no-build "$service"; then
  log_error "Failed to start Docker containers for ${args[APP_NAME]} ($env_name)"
  log_error "  Logs:    ./ez dotnet logs ${args[APP_NAME]} $env_name"
  log_error "  Env:     $merged_env_path"
  exit 1
fi

if wait_for_healthy "$container"; then
  record_deployed_tag "${args[APP_NAME]}" "$env_name" "$new_tag"
  log_success "Server running on [$container] container with 'inner' port 8080 ($new_tag)."
else
  docker logs --tail 60 "$container" 2>&1 || true
  log_error "$container did not become healthy (GET /healthz)."
  if [[ "$DEPLOY_MODE" == "image" && -n "$previous_tag" && "$previous_tag" != "$new_tag" ]]; then
    log_warning "Rolling back to $previous_tag"
    APP_IMAGE="$(image_name "$APP_IMAGE"):$previous_tag"
    export APP_IMAGE
    if dotnet_compose up -d --no-build "$service" && wait_for_healthy "$container"; then
      log_warning "Rolled back to $previous_tag."
    else
      log_error "The rollback is not healthy either."
    fi
  elif [[ "$DEPLOY_MODE" == "build" ]] && docker image inspect "${args[APP_NAME]}:$env_name-previous" >/dev/null 2>&1; then
    log_warning "Rolling back to the previous build"
    docker tag "${args[APP_NAME]}:$env_name-previous" "${args[APP_NAME]}:$env_name"
    if dotnet_compose up -d --no-build "$service" && wait_for_healthy "$container"; then
      log_warning "Rolled back to the previous build."
    else
      log_error "The rollback is not healthy either."
    fi
  fi
  exit 1
fi

if [[ "$env_name" == "test" ]]; then
  if [[ -n "$APP_PORT" ]]; then
    log_success "Server running on [http://<your_ip>:$APP_PORT]."
  else
    log_error "APP_PORT not set for test. Add it to $app_dir/env/test.env, e.g. APP_PORT=8000"
    exit 1
  fi
else
  log_info "Connect a domain in Nginx Proxy Manager: forward to $container, port 8080 (admin UI: ssh -L ${PORT_NGINX_PM:-81}:127.0.0.1:${PORT_NGINX_PM:-81} <server>)."
fi
