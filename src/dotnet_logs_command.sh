prepare_app

# shellcheck disable=SC2046 # one word per service
dotnet_compose logs -f --tail 200 $(app_services)
