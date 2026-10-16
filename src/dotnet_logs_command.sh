prepare_app

dotnet_compose logs -f --tail 200 "$(dotnet_service)"
