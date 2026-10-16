prepare_app

# shellcheck disable=SC2046 # one word per service
dotnet_compose stop $(app_services)
