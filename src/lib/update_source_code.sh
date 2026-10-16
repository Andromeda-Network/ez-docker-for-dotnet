update_source_code() {
  log_info "updating source code ..."
  local source_code_dir="apps/${args[APP_NAME]}/src-${args[APP_ENV]}"

  if [ -d "$source_code_dir/.git" ]; then
      log "Updating existing $source_code_dir folder ($GIT_BRANCH)"
      # fetch + reset, not pull: the checkout is a build input, never edited on the server
      # (dev's is, and keeps pull so local edits are not thrown away).
      if [[ "${args[APP_ENV]}" == "dev" ]]; then
          git -C "$source_code_dir" pull origin "$GIT_BRANCH" || { log_error "Error: Git pull failed."; exit 1; }
      else
          git -C "$source_code_dir" fetch --depth 1 origin "$GIT_BRANCH" \
            && git -C "$source_code_dir" reset --hard "origin/$GIT_BRANCH" \
            || { log_error "Error: Git fetch failed."; exit 1; }
      fi
  else
      log "Cloning new $source_code_dir folder"
      git clone --depth 1 -b "$GIT_BRANCH" "$GIT_URL" "$source_code_dir" || { log_error "Error: Git cloning failed."; exit 1; }
  fi

  # The build context is the repository root; keep bin/obj, .git and env files out of it.
  if [ ! -f "$source_code_dir/.dockerignore" ]; then
      cp "apps/${args[APP_NAME]}/.dockerignore" "$source_code_dir/.dockerignore"
  fi

  local svc project dockerfile context
  for svc in $(app_services); do
    context="$source_code_dir/$(svc_get "$svc" CONTEXT)"
    project=$(svc_project "$svc")
    dockerfile=$(svc_get "$svc" DOCKERFILE)
    if [[ -n "$project" && ! -f "$source_code_dir/$project" && ! -f "$context/$project" ]]; then
      log_error "Error: $svc's project not found: $project"
      log_error "Set $( [[ "$svc" == web ]] && echo PROJECT || echo "$(svc_key "$svc")_PROJECT") in apps/${args[APP_NAME]}/env/app.env, relative to the repository root."
      exit 1
    fi
    if [[ -n "$dockerfile" && ! -f "$context/$dockerfile" ]]; then
      log_error "Error: $svc's Dockerfile not found: $context/$dockerfile"
      exit 1
    fi
  done

  log_success "Source ready: $source_code_dir ($(git -C "$source_code_dir" rev-parse --short HEAD))"
}
