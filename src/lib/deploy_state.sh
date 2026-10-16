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
    sleep "${EZ_POLL_SECONDS:-3}"
    waited=$((waited + 3))
  done
  return 1
}

# Running, and still the same run 10 seconds later (a crash loop restarts it): for services
# without HTTP, such as workers.
wait_for_running() {
  local container=$1 timeout=${2:-120} waited=0 started
  log_info "Waiting for $container to keep running ..."
  while (( waited < timeout )); do
    case "$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo missing)" in
      running)
        started=$(docker inspect -f '{{.State.StartedAt}}' "$container" 2>/dev/null)
        sleep "${EZ_SETTLE_SECONDS:-10}"
        if [[ "$(docker inspect -f '{{.State.Status}} {{.State.StartedAt}}' "$container" 2>/dev/null)" == "running $started" ]]; then
          return 0
        fi
        ;;
      exited|dead|missing) (( waited > 10 )) && return 1 ;;
    esac
    sleep "${EZ_POLL_SECONDS:-3}"
    waited=$((waited + 13))
  done
  return 1
}

# GET http://<container>:8080<path> from this host, through the container's address on the shared
# network: works for images without curl (Microsoft's chiseled images, apps' own Dockerfiles).
wait_for_http() {
  local container=$1 path=$2 timeout=${3:-180} waited=0 ip
  log_info "Waiting for $container to answer GET $path (up to ${timeout}s) ..."
  while (( waited < timeout )); do
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$container" 2>/dev/null | awk '{print $1}')
    if [[ -n "$ip" ]] && curl -fsS -o /dev/null -m 5 "http://$ip:8080$path" 2>/dev/null; then
      return 0
    fi
    case "$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo missing)" in
      exited|dead|missing) (( waited > 10 )) && return 1 ;;
    esac
    sleep "${EZ_POLL_SECONDS:-3}"
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
