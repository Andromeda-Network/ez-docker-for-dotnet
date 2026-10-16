prepare_app

if [[ "$DEPLOY_MODE" != "image" ]]; then
  log_error "Rollback to a tag needs DEPLOY_MODE=image. In build mode, deploy an earlier commit"
  log_error "(a failed build-mode deploy already swaps the previous build back by itself)."
  exit 1
fi

if ! validate_image_tag "${args[TAG]}"; then
  log_error "Invalid tag: ${args[TAG]}"
  exit 1
fi

# The same path as a deploy: pull, (migrate), start, health-check, and undo if unhealthy.
args[--tag]="${args[TAG]}"
ez_dotnet_deploy_command
