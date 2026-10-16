DOCKER_ENV_PATH="docker/docker.env"
if [[ ! -f "$DOCKER_ENV_PATH" ]]; then
  log_error "Set up the shared services first (they decide the database and Redis password):"
  log_error "  ./ez shared deploy"
  exit 1
fi
load_env "$DOCKER_ENV_PATH" >/dev/null

APP_NAME=$(ask_question "Enter the application name" "")

# Validate application name
if ! validate_app_name "$APP_NAME"; then
  log_error "Invalid application name: $APP_NAME"
  log_error "Application names must:"
  log_error "  - Contain only letters, numbers, hyphens, and underscores"
  log_error "  - Be 64 characters or less"
  log_error "Example: my-dotnet-app"
  exit 1
fi

APP_DIR="apps/$APP_NAME"

if [[ -d "$APP_DIR" ]]; then
    log_error "Directory $APP_DIR already exists app_name must be unique."
    exit 1
fi

while true; do
  # Set default suggestion - if current user is root, suggest ubuntu instead
  if [[ "$(whoami)" == "root" ]]; then
    DEFAULT_USER="${SUDO_USER:-ubuntu}"
  else
    DEFAULT_USER="$(whoami)"
  fi

  OWNER_USER_NAME=$(ask_question "What user on this host machine owns this app" "$DEFAULT_USER")

  # Check if user is trying to use root
  if [[ "$OWNER_USER_NAME" == "root" ]]; then
    log_error "Root user is not supported for security reasons. Try using 'ubuntu' or create a dedicated user for your application."
    continue
  fi

  if user_exists "$OWNER_USER_NAME"; then
    # Additional check for UID 0 (root)
    USER_ID=$(id -u "$OWNER_USER_NAME")
    if [[ "$USER_ID" == "0" ]]; then
      log_error "User '$OWNER_USER_NAME' has root privileges (UID 0). Try using 'ubuntu' or create a dedicated user for your application."
      continue
    fi
    break
  else
    log_error "User '$OWNER_USER_NAME' does not exist. Please enter a valid user."
  fi
done

OWNER_USER_ID=$(id -u "$OWNER_USER_NAME")
OWNER_GROUP_NAME=$(id -gn "$OWNER_USER_NAME")
OWNER_GROUP_ID=$(id -g "$OWNER_USER_NAME")

log_info "Git url examples:"
log "normal git url (you get prompted for authorization): https://github.com/your-org/your-app.git"
log "or this format: https://<user>:<token>@github.com/your-org/your-app.git"
GIT_URL=$(ask_question "Enter the application git url" "https://github.com/your-org/your-app.git")

# Validate Git URL
if ! validate_git_url "$GIT_URL"; then
  log_error "Invalid Git URL format: $GIT_URL"
  log_error "Git URLs must end with .git and use https://, http://, git://, or git@"
  exit 1
fi

log_info "The project to publish, relative to the repository root (the one with Program.cs)."
while true; do
  PROJECT=$(ask_question "Enter the project path" "src/$APP_NAME/$APP_NAME.csproj")
  if validate_project_path "$PROJECT"; then
    break
  fi
done

log_info ".NET version for this app (supported: 8.0, 9.0, 10.0)"
while true; do
  DOTNET_VERSION=$(ask_question "Enter the .NET version" "10.0")
  if validate_dotnet_version "$DOTNET_VERSION"; then
    break
  fi
done

log_info "Deploy mode for staging/production: 'build' builds on this host from git; 'image' pulls"
log "the image CI built and tested (recommended; see .github.example/workflows/release.yml)."
while true; do
  DEPLOY_MODE=$(ask_question "Enter the deploy mode (build/image)" "image")
  [[ "$DEPLOY_MODE" == "build" || "$DEPLOY_MODE" == "image" ]] && break
  log_error "Deploy mode must be build or image."
done
APP_IMAGE=""
if [[ "$DEPLOY_MODE" == "image" ]]; then
  APP_IMAGE=$(ask_question "Enter the image (registry/owner/name:tag)" "ghcr.io/your-org/$APP_NAME:latest")
fi

MIGRATIONS=$(ask_question "Run EF Core migrations on every deploy? (true/false)" "false")
[[ "$MIGRATIONS" == "true" ]] || MIGRATIONS=false

log "Creating $APP_DIR directory"
mkdir -p "$APP_DIR/env/generated"

cat <<EOL > "$APP_DIR/env/app.env"
APP_NAME=$APP_NAME
GIT_URL=$GIT_URL
PROJECT=$PROJECT
# The project holding the DbContext and migrations, if not PROJECT.
EF_PROJECT=
DOTNET_VERSION=$DOTNET_VERSION
DEPLOY_MODE=$DEPLOY_MODE
APP_IMAGE=$APP_IMAGE
MIGRATIONS=$MIGRATIONS
# Runs on the host before migrations (e.g. a database backup); a failure stops the deploy.
PRE_MIGRATION_COMMAND=
OWNER_USER_NAME=$OWNER_USER_NAME
OWNER_USER_ID=$OWNER_USER_ID
OWNER_GROUP_NAME=$OWNER_GROUP_NAME
OWNER_GROUP_ID=$OWNER_GROUP_ID
EOL

log_info "created $APP_DIR/env/app.env"

for environment in dev test staging production; do
  default=yes
  [[ "$environment" == "dev" ]] && default=no
  answer=$(ask_question "Do you want to set up the $environment environment?" "$default")
  if [[ "$answer" == "yes" || "$answer" == "y" ]]; then
    setup_environment "$APP_NAME" "$environment"
  fi
done

cp "template/dotnet.Dockerfile" "$APP_DIR/dotnet.Dockerfile"
cp "template/.dockerignore" "$APP_DIR/.dockerignore"
cp "template/common-dotnet.yml" "$APP_DIR/common-dotnet.yml"
cp "template/compose-dotnet.yml" "$APP_DIR/compose-dotnet.yml"
cp "template/compose-dotnet-image.yml" "$APP_DIR/compose-dotnet-image.yml"

chown -R "$OWNER_USER_NAME:$OWNER_GROUP_NAME" "$APP_DIR" 2>/dev/null || true
chmod 700 "$APP_DIR/env"

log_success "App $APP_NAME is set up in $APP_DIR."
log_info "Add your settings and secrets to $APP_DIR/env/<env>.env (Section__Key), then:"
log "  ./ez dotnet deploy $APP_NAME <env>"
