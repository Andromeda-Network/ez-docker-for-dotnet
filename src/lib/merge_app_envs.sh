merge_app_envs() {
  local app_dir=$1
  local app_env=$2

  docker_env_path="docker/docker.env"
  app_env_path="$app_dir/env/app.env"
  override_env_path="$app_dir/env/$app_env.env"
  merged_env_path="$app_dir/env/generated/$app_env.env"

  mkdir -p "$app_dir/env/generated"
  merge_envs "$merged_env_path" "$docker_env_path" "$app_env_path" "$override_env_path"
  # The merged file is the app's environment (env_file) and holds its secrets.
  chmod 600 "$merged_env_path"

  echo "$merged_env_path"
}
