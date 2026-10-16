prepare_app

dotnet_compose ps
log_info "Deploy mode: $DEPLOY_MODE"
log_info "Deployed version: $(read_deployed_tag "${args[APP_NAME]}" "${args[APP_ENV]}" | grep . || echo 'none yet')"
