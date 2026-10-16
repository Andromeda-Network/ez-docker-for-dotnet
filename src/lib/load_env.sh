load_env() {
  local filePath="${1:-.env}"

  if [ ! -f "$filePath" ]; then
    echo "missing ${filePath}"
    exit 1
  fi

  while read -r LINE; do
    # Remove leading and trailing whitespaces, and carriage return
    CLEANED_LINE=$(echo "$LINE" | awk '{$1=$1};1' | tr -d '\r')

    if [[ $CLEANED_LINE != '#'* ]] && [[ $CLEANED_LINE == *'='* ]]; then
      # Only names a shell can hold. .NET settings like Logging__LogLevel__Default are fine; a
      # name with '-' or '.' still reaches the container through env_file, just not this shell.
      if [[ "${CLEANED_LINE%%=*}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        export "${CLEANED_LINE?}"
      fi
    fi
  done < "$filePath"

  log "loaded env file: $filePath"
}
