prepare_app

if [[ "${args[APP_ENV]}" == "dev" && -n "${args[--update]}" ]]; then
  update_source_code
fi

# shellcheck disable=SC2046 # one word per service
dotnet_compose restart $(app_services)
