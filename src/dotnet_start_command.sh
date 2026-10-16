prepare_app

if [[ "${args[APP_ENV]}" == "dev" && -n "${args[--update]}" ]]; then
  update_source_code
fi

dotnet_compose start "$(dotnet_service)"
