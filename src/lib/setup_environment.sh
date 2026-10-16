setup_environment() {
  local app_name=$1
  local environment=$2

  local branch_name db_database db_username generated_password db_password aspnet_env app_port db_host connection

  if [ "$environment" == "production" ]; then
    branch_name="main"
  else
    branch_name="$environment"
  fi

  branch_name=$(ask_question "Enter the ${environment} branch name" "$branch_name")

  # SQL identifiers: the app name's '-' becomes '_'.
  db_database=$(ask_question "Enter the ${environment} database name" "${app_name//-/_}_${environment}")
  db_username=$(ask_question "Enter the ${environment} database username" "${app_name//-/_}_${environment}_user")
  generated_password=$(generate_password 24)
  db_password=$(ask_question "Enter the $db_username's password" "$generated_password")

  app_port=""
  case "$environment" in
    dev)        aspnet_env=Development; app_port=$(assign_port "dev" 7000) ;;
    test)       aspnet_env=Test;        app_port=$(assign_port "test" 8000) ;;
    staging)    aspnet_env=Staging ;;
    production) aspnet_env=Production ;;
  esac

  case "${DB_ENGINE:-mssql}" in
    postgres) connection="Host=postgres;Database=$db_database;Username=$db_username;Password=$db_password" ;;
    none)     connection="" ;;
    *)        connection="Server=mssql;Database=$db_database;User Id=$db_username;Password=$db_password;TrustServerCertificate=True;MultipleActiveResultSets=True" ;;
  esac

  cat <<EOL > "apps/$app_name/env/$environment.env"
GIT_BRANCH=$branch_name
APP_ENV=$environment
ASPNETCORE_ENVIRONMENT=$aspnet_env
APP_PORT=$app_port
DB_DATABASE=$db_database
DB_USERNAME=$db_username
DB_PASSWORD=$db_password
# The app's settings: .NET reads nested keys with __ (Section__Key).
ConnectionStrings__Default=$connection
ConnectionStrings__Redis=redis:6379,password=${REDIS_PASSWORD}
Seq__ServerUrl=http://seq:5341
EOL
  chmod 600 "apps/$app_name/env/$environment.env"

  log_info "created apps/$app_name/env/$environment.env"
}
