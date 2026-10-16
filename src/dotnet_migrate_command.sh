prepare_app

if [[ "$DEPLOY_MODE" == "image" ]]; then
  # The migrations image of the deployed version (ez_image_tag).
  registry_login "$REGISTRY_HOST" "$REGISTRY_USER" "$REGISTRY_TOKEN"
  dotnet_compose --profile migrate pull migrate
else
  dotnet_compose --profile migrate build migrate
fi

log_info "Applying EF Core migrations to ${args[APP_NAME]} (${args[APP_ENV]})"
dotnet_compose --profile migrate run --rm migrate
