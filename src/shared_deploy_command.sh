DOCKER_ENV_PATH="docker/docker.env"

if [[ -f "$DOCKER_ENV_PATH" ]]; then
  load_env "$DOCKER_ENV_PATH"
else
  log_warning "$DOCKER_ENV_PATH not found."
  log_info "Creating new '$DOCKER_ENV_PATH' file."

  SHARED_NETWORK_NAME=$(ask_question "Enter the docker network name" "ez-shared-network")
  PORT_NGINX_PM=$(ask_question "Enter the Nginx Proxy Manager admin port (bound to 127.0.0.1)" "81")
  while true; do
    DB_ENGINE=$(ask_question "Database server for the apps (mssql, postgres or none)" "mssql")
    [[ "$DB_ENGINE" =~ ^(mssql|postgres|none)$ ]] && break
    log_error "Choose mssql, postgres or none."
  done
  SHARED_PROFILES=$(ask_question "Optional shared services (seq portainer, space-separated, or empty)" "seq")

  # generate_password's alphabet (letters, digits, @%&*) is safe unquoted in env files and
  # connection strings. SQL Server's policy wants mixed case and a digit: the suffix guarantees it.
  umask 077
  cat <<EOL > "$DOCKER_ENV_PATH"
SHARED_NETWORK_NAME=$SHARED_NETWORK_NAME
DB_ENGINE=$DB_ENGINE
SHARED_PROFILES=$SHARED_PROFILES

PORT_NGINX_PM=$PORT_NGINX_PM
PORT_SEQ=5380
PORT_PORTAINER=9443

MSSQL_SA_PASSWORD=$(generate_password 24)Aa1
# Express is free and licensed for production (limited); Developer is not for production.
MSSQL_PID=Express
POSTGRES_PASSWORD=$(generate_password 24)
REDIS_PASSWORD=$(generate_password 24)
SEQ_ADMIN_PASSWORD=$(generate_password 20)

# Pinned versions (see .env.example)
NGINX_PM_VERSION=2.11.1
MSSQL_VERSION=2022-latest
POSTGRES_VERSION=17.2-alpine
REDIS_VERSION=7.4.1-alpine
SEQ_VERSION=2024.3
PORTAINER_VERSION=2.19.4

# Image mode: the registry apps are pulled from (both empty: anonymous pulls).
REGISTRY_HOST=ghcr.io
REGISTRY_USER=
REGISTRY_TOKEN=
EOL
  umask 022

  log_success "Saved docker environment variables to $DOCKER_ENV_PATH (passwords generated; keep it private)"
  load_env "$DOCKER_ENV_PATH"
fi

# Check if the network already exists
if docker network inspect "$SHARED_NETWORK_NAME" >/dev/null 2>&1; then
  log "Network '$SHARED_NETWORK_NAME' already exists"
else
  if docker network create "$SHARED_NETWORK_NAME"; then
    log_success "Network '$SHARED_NETWORK_NAME' created"
  else
    log_error "Failed to create network '$SHARED_NETWORK_NAME'"
    exit 1
  fi
fi

log_header "Running Docker Compose for shared services"

if ! shared_compose up -d --remove-orphans; then
  log_error "Failed to run Docker Compose"
  exit 1
fi

log_success "Shared services are up (database: ${DB_ENGINE}; optional: ${SHARED_PROFILES:-none})."
log_info "Nginx Proxy Manager admin: ssh -L ${PORT_NGINX_PM}:127.0.0.1:${PORT_NGINX_PM} <server>, then http://localhost:${PORT_NGINX_PM}"
if [[ " ${SHARED_PROFILES} " == *" seq "* ]]; then
  log_info "Seq (logs and errors): ssh -L ${PORT_SEQ}:127.0.0.1:${PORT_SEQ} <server>, then http://localhost:${PORT_SEQ} (admin / SEQ_ADMIN_PASSWORD)"
fi
