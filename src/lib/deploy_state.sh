# The image tag last deployed to an environment, so a failed deploy can roll back to it.
deployed_tag_file() { echo "apps/$1/env/generated/$2.deployed"; }

read_deployed_tag() { cat "$(deployed_tag_file "$1" "$2")" 2>/dev/null || true; }

record_deployed_tag() { echo "$3" > "$(deployed_tag_file "$1" "$2")"; }

# Wait for a container's health check (the app's /healthz). A container without a health check
# counts once it is running.
wait_for_healthy() {
  local container=$1 timeout=${2:-180} waited=0 state
  log_info "Waiting for $container to become healthy (up to ${timeout}s) ..."
  while (( waited < timeout )); do
    state=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || echo missing)
    case "$state" in
      healthy|running) return 0 ;;
      unhealthy|exited|dead) (( waited > 10 )) && return 1 ;;
    esac
    sleep 3
    waited=$((waited + 3))
  done
  return 1
}

# An image reference without its tag: registry.example.com:5000/group/app:v1 -> .../group/app
# (a ':' after the last '/' is the tag; a registry port before it stays).
image_name() {
  local image=$1
  if [[ "${image##*/}" == *:* ]]; then image=${image%:*}; fi
  echo "$image"
}

image_tag() {
  local image=$1
  if [[ "${image##*/}" == *:* ]]; then echo "${image##*:}"; else echo latest; fi
}
