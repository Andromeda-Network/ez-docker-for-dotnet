#inspect_args

prepare_app

env_name="${args[APP_ENV]}"
services=$(app_services)

log_header "Preparing to deploy ${args[APP_NAME]} (.NET) in $env_name mode: $services"

if [[ -n "${IMAGE_MODE_APP:-}" ]]; then
  log_info "DEPLOY_MODE=image applies to staging and production; $env_name builds from $GIT_BRANCH."
fi

if [[ "$DEPLOY_MODE" == "image" ]]; then
  # The images already contain the application, so this host needs no source or SDK; CI built
  # and tested them.
  if [[ -z "$APP_IMAGE" ]]; then
    log_error "DEPLOY_MODE=image but APP_IMAGE is empty. Set it in $app_dir/env/app.env, e.g."
    log_error "  APP_IMAGE=ghcr.io/your-org/your-app:latest"
    exit 1
  fi
  EZ_TAG="${args[--tag]:-$(image_tag "$APP_IMAGE")}"
  if ! validate_image_tag "$EZ_TAG"; then
    log_error "Invalid --tag: $EZ_TAG"
    exit 1
  fi
  export EZ_TAG
  log_info "Image mode — deploying tag $EZ_TAG (no source checkout, no build on this host)."
else
  if [[ -n "${args[--tag]}" ]]; then
    log_error "--tag is for DEPLOY_MODE=image; build mode builds GIT_BRANCH's head."
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
  # shellcheck disable=SC2086 # one word per service
  if ! dotnet_compose up -d --remove-orphans $services; then
    log_error "Failed to start ${args[APP_NAME]} (dev). Logs: ./ez dotnet logs ${args[APP_NAME]} dev"
    exit 1
  fi
  log_success "Running ${args[APP_NAME]} dev: dotnet watch on $app_dir/src-dev"
  exit 0
fi

# The data volume belongs to the image's app user (uid 1654 in Microsoft's .NET images), not the
# host's; it must exist with that owner before the containers' first write.
storage_dir="$app_dir/storage-$env_name"
mkdir -p "$storage_dir"
if ! chown -R "${IMAGE_USER_ID:-1654}:${IMAGE_GROUP_ID:-1654}" "$storage_dir"; then
  log_error "Cannot give $storage_dir to the container's user (uid ${IMAGE_USER_ID:-1654}): run ez with sudo."
  exit 1
fi

previous_tag=$(read_deployed_tag "${args[APP_NAME]}" "$env_name")

log_header "Preparing the new version of ${args[APP_NAME]} ($env_name)"
if [[ "$DEPLOY_MODE" == "image" ]]; then
  registry_login "$REGISTRY_HOST" "$REGISTRY_USER" "$REGISTRY_TOKEN"
  # Pull first, so a registry or tag problem fails before any running container is touched.
  # shellcheck disable=SC2086
  if ! dotnet_compose pull $services; then
    log_error "Could not pull the $EZ_TAG images of: $services."
    exit 1
  fi
  if [[ "${MIGRATIONS:-false}" == "true" ]] && ! dotnet_compose --profile migrate pull migrate; then
    log_error "Could not pull the migrations image (CI publishes it when MIGRATIONS=true)."
    exit 1
  fi
  new_tag="$EZ_TAG"
else
  # Keep each running image as <image>-previous, so an unhealthy build can be swapped back.
  for svc in $services; do
    image=$(svc_build_image "$svc")
    if docker image inspect "$image" >/dev/null 2>&1; then
      docker tag "$image" "$image-previous"
    fi
  done
  # shellcheck disable=SC2086
  if ! dotnet_compose build $services; then
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
# shellcheck disable=SC2086
if ! dotnet_compose up -d --no-build --remove-orphans $services; then
  log_error "Failed to start Docker containers for ${args[APP_NAME]} ($env_name)"
  log_error "  Logs:    ./ez dotnet logs ${args[APP_NAME]} $env_name"
  log_error "  Env:     $merged_env_path"
  exit 1
fi

if wait_for_all_services; then
  record_deployed_tag "${args[APP_NAME]}" "$env_name" "$new_tag"
  for svc in $services; do
    port=$(svc_port "$svc")
    log_success "$svc: container [$(svc_container "$svc")], inner port 8080${port:+, http://<your_ip>:$port} ($new_tag)"
  done
  if [[ "$env_name" != "test" ]]; then
    log_info "Connect a domain in Nginx Proxy Manager: forward to a container above, port 8080 (admin UI: ssh -L ${PORT_NGINX_PM:-81}:127.0.0.1:${PORT_NGINX_PM:-81} <server>)."
  fi
  exit 0
fi

# Not every service came up: put all of them back, together.
if [[ "$DEPLOY_MODE" == "image" && -n "$previous_tag" && "$previous_tag" != git-* && "$previous_tag" != "$new_tag" ]]; then
  log_warning "Rolling back every service to $previous_tag"
  EZ_TAG="$previous_tag"
  export EZ_TAG
  # shellcheck disable=SC2086
  if dotnet_compose up -d --no-build $services && wait_for_all_services; then
    log_warning "Rolled back to $previous_tag."
  else
    log_error "The rollback is not healthy either."
  fi
elif [[ "$DEPLOY_MODE" == "build" ]]; then
  restored=0
  for svc in $services; do
    image=$(svc_build_image "$svc")
    if docker image inspect "$image-previous" >/dev/null 2>&1; then
      docker tag "$image-previous" "$image"
      restored=1
    fi
  done
  if (( restored )); then
    log_warning "Rolling back to the previous build"
    # shellcheck disable=SC2086
    if dotnet_compose up -d --no-build $services && wait_for_all_services; then
      log_warning "Rolled back to the previous build."
    else
      log_error "The rollback is not healthy either."
    fi
  fi
fi
exit 1
