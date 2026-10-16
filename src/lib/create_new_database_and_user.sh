# Create the app environment's database and its own login on the shared database server
# (DB_ENGINE in docker/docker.env: mssql, postgres, or none to skip). Idempotent: an existing
# database is kept, an existing login gets the password from the env file again.
#
# Names reach SQL as identifiers, so they are validated first (letters, digits, _ only).
# Passwords travel as environment variables: `docker exec -e NAME` (no value) copies NAME from
# this process's environment, so no password appears on a command line (`ps`), host or container.
create_new_database_and_user() {

  if [ "$#" -ne 3 ]; then
      log_error "Invalid Arguments, Usage: $0 <new_db_name> <new_user_name> <new_user_password>"
      return 1
  fi

  local db_name=$1 user_name=$2 user_password=$3
  local engine="${DB_ENGINE:-mssql}"

  if [[ "$engine" == "none" ]]; then
    log_info "DB_ENGINE=none: not creating a database."
    return 0
  fi

  if [[ ! "$db_name" =~ ^[A-Za-z_][A-Za-z0-9_]{0,63}$ || ! "$user_name" =~ ^[A-Za-z_][A-Za-z0-9_]{0,63}$ ]]; then
    log_error "Database and user names must be letters, digits and _ (got '$db_name', '$user_name')."
    exit 1
  fi
  if [[ -z "$user_password" || "$user_password" == *"'"* || "$user_password" == *"]"* ]]; then
    log_error "DB_PASSWORD for $user_name must be set and must not contain ' or ]."
    exit 1
  fi

  log_header "Creating Database: $db_name with User: $user_name ($engine)"

  case "$engine" in
    mssql)
      # sqlcmd reads $(DB), $(USR) and $(PWD_) from its environment, and the sa password from
      # SQLCMDPASSWORD.
      if ! SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" DB="$db_name" USR="$user_name" PWD_="$user_password" \
          docker exec -i -e SQLCMDPASSWORD -e DB -e USR -e PWD_ \
          mssql /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -b <<'SQL'
IF DB_ID(N'$(DB)') IS NULL EXEC(N'CREATE DATABASE [$(DB)]');
IF SUSER_ID(N'$(USR)') IS NULL
    EXEC(N'CREATE LOGIN [$(USR)] WITH PASSWORD = N''$(PWD_)'', CHECK_POLICY = OFF, DEFAULT_DATABASE = [$(DB)]');
ELSE
    EXEC(N'ALTER LOGIN [$(USR)] WITH PASSWORD = N''$(PWD_)''');
EXEC(N'USE [$(DB)];
IF USER_ID(N''$(USR)'') IS NULL CREATE USER [$(USR)] FOR LOGIN [$(USR)];
ALTER ROLE db_owner ADD MEMBER [$(USR)];');
SQL
      then
        log_error "Failed to create database '$db_name' or login '$user_name' on mssql."
        exit 1
      fi
      ;;
    postgres)
      # The new role's password is a psql variable set from the script itself (\getenv), not argv.
      if ! PGPASSWORD="$POSTGRES_PASSWORD" EZ_DB="$db_name" EZ_USR="$user_name" EZ_PWD="$user_password" \
          docker exec -i -e PGPASSWORD -e EZ_DB -e EZ_USR -e EZ_PWD postgres \
          psql -v ON_ERROR_STOP=1 -U postgres <<'SQL'
\getenv db EZ_DB
\getenv usr EZ_USR
\getenv pwd EZ_PWD
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'usr', :'pwd') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'usr') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', :'usr', :'pwd') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'usr') WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db') \gexec
SQL
      then
        log_error "Failed to create database '$db_name' or role '$user_name' on postgres."
        exit 1
      fi
      ;;
    *)
      log_error "Unknown DB_ENGINE '$engine' (mssql, postgres or none)."
      exit 1
      ;;
  esac

  log_success "Database $db_name ready; $user_name owns it."
}
