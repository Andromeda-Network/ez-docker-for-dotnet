prepare_app

if [[ "$DEPLOY_MODE" == "image" && "${args[APP_ENV]}" != "dev" && "${args[APP_ENV]}" != "test" ]]; then
  # The migrations image matching the deployed version.
  deployed=$(read_deployed_tag "${args[APP_NAME]}" "${args[APP_ENV]}")
  MIGRATIONS_IMAGE="$(image_name "$APP_IMAGE")-migrations:${deployed:-$(image_tag "$APP_IMAGE")}"
  export MIGRATIONS_IMAGE
  registry_login "$REGISTRY_HOST" "$REGISTRY_USER" "$REGISTRY_TOKEN"
  dotnet_compose --profile migrate pull migrate
else
  dotnet_compose --profile migrate build migrate
fi

log_info "Applying EF Core migrations to ${args[APP_NAME]} (${args[APP_ENV]})"
dotnet_compose --profile migrate run --rm migrate
