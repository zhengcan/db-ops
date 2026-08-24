#!/usr/bin/env bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../my-ops.sh"
  export DB_OPS_TEST=1
  # shellcheck disable=SC1090
  . "$SCRIPT"
}

# ===================== INI parsing basics =====================

@test "list_config_instances lists all instance names in order" {
  cfg="$(mktemp)"
  cat > "$cfg" <<'EOF'
[prod]
type = mysql
host = prodhost

[analytics]
type = pg
host = analyticshost

[staging]
type = mysql
host = staginghost
EOF
  result="$(list_config_instances "$cfg")"
  expected="$(printf 'prod\nanalytics\nstaging')"
  [ "$result" = "$expected" ]
  rm -f "$cfg"
}

@test "load_config_instance extracts type/host/port/user/password/database" {
  cfg="$(mktemp)"
  cat > "$cfg" <<'EOF'
[prod]
type = mysql
host = mysql.prod.internal
port = 3306
user = backup_user
password = secret
database = mydb
EOF
  load_config_instance "$cfg" prod
  [ "$CONFIG_INSTANCE_TYPE" = "mysql" ]
  [ "$DB_HOST" = "mysql.prod.internal" ]
  [ "$DB_PORT" = "3306" ]
  [ "$DB_USER" = "backup_user" ]
  [ "$DB_PASSWORD" = "secret" ]
  [ "$DB_DATABASE" = "mydb" ]
  rm -f "$cfg"
}

@test "load_config_instance accepts both 'key = value' and 'key=value' forms" {
  cfg="$(mktemp)"
  cat > "$cfg" <<'EOF'
[mixed]
type=mysql
host = spacedhost
port=1234
EOF
  load_config_instance "$cfg" mixed
  [ "$CONFIG_INSTANCE_TYPE" = "mysql" ]
  [ "$DB_HOST" = "spacedhost" ]
  [ "$DB_PORT" = "1234" ]
  rm -f "$cfg"
}

@test "load_config_instance ignores comment lines, blank lines, and unknown keys" {
  cfg="$(mktemp)"
  cat > "$cfg" <<'EOF'
[prod]
# this is a comment
; this is also a comment
type = mysql

foo = bar
host = commenthost
EOF
  run load_config_instance "$cfg" prod
  [ "$status" -eq 0 ]
  load_config_instance "$cfg" prod
  [ "$CONFIG_INSTANCE_TYPE" = "mysql" ]
  [ "$DB_HOST" = "commenthost" ]
  rm -f "$cfg"
}

# ===================== instance selection logic =====================

@test "resolve_config_instance auto-selects the only instance when there is exactly one" {
  cfg="$(mktemp)"
  cat > "$cfg" <<'EOF'
[only]
type = mysql
host = onlyhost
port = 3306
user = onlyuser
password = onlypass
EOF
  CONFIG_FILE="$cfg"
  resolve_config_instance
  [ "$DB_HOST" = "onlyhost" ]
  [ "$DB_USER" = "onlyuser" ]
  rm -f "$cfg"
}

@test "resolve_config_instance dies listing available instances when 2+ instances and no --instance given" {
  cfg="$(mktemp)"
  cat > "$cfg" <<'EOF'
[prod]
type = mysql
host = prodhost

[staging]
type = mysql
host = staginghost
EOF
  CONFIG_FILE="$cfg"
  run resolve_config_instance
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"prod"* ]]
  [[ "$output" == *"staging"* ]]
  rm -f "$cfg"
}

@test "resolve_config_instance loads the named instance when --instance matches" {
  cfg="$(mktemp)"
  cat > "$cfg" <<'EOF'
[prod]
type = mysql
host = prodhost
user = produser

[staging]
type = mysql
host = staginghost
user = staginguser
EOF
  CONFIG_FILE="$cfg"
  INSTANCE_NAME="staging"
  resolve_config_instance
  [ "$DB_HOST" = "staginghost" ]
  [ "$DB_USER" = "staginguser" ]
  rm -f "$cfg"
}

@test "resolve_config_instance dies listing available instances when --instance does not match any" {
  cfg="$(mktemp)"
  cat > "$cfg" <<'EOF'
[prod]
type = mysql
host = prodhost

[staging]
type = mysql
host = staginghost
EOF
  CONFIG_FILE="$cfg"
  INSTANCE_NAME="nosuch"
  run resolve_config_instance
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"nosuch"* ]]
  [[ "$output" == *"prod"* ]]
  [[ "$output" == *"staging"* ]]
  rm -f "$cfg"
}

@test "resolve_config_instance dies with a clear error when a single instance's name doesn't match --instance" {
  cfg="$(mktemp)"
  cat > "$cfg" <<'EOF'
[only]
type = mysql
host = onlyhost
EOF
  CONFIG_FILE="$cfg"
  INSTANCE_NAME="wrong"
  run resolve_config_instance
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"wrong"* ]]
  [[ "$output" == *"only"* ]]
  rm -f "$cfg"
}

@test "resolve_config_instance dies when config file defines no instances" {
  cfg="$(mktemp)"
  cat > "$cfg" <<'EOF'
# no instances here, just comments
EOF
  CONFIG_FILE="$cfg"
  run resolve_config_instance
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"no instances"* || "$output" == *"instance"* ]]
  rm -f "$cfg"
}

@test "resolve_config_instance dies when the selected instance's type is not mysql" {
  cfg="$(mktemp)"
  cat > "$cfg" <<'EOF'
[analytics]
type = pg
host = pghost
EOF
  CONFIG_FILE="$cfg"
  run resolve_config_instance
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"analytics"* ]]
  [[ "$output" == *"pg"* ]]
  [[ "$output" == *"mysql"* ]]
  rm -f "$cfg"
}

# ===================== CLI overrides config instance =====================

@test "main: CLI --host overrides the host loaded from a config instance" {
  cfg="$(mktemp)"
  cat > "$cfg" <<'EOF'
[prod]
type = mysql
host = cfghost
EOF
  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; main --config "'"$cfg"'" --host clihost help; echo "DB_HOST=$DB_HOST"'
  rm -f "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DB_HOST=clihost"* ]]
}

# ===================== default discovery behavior =====================

@test "main auto-discovers ./dbs.conf in the current directory when --config is not given" {
  workdir="$(mktemp -d)"
  cat > "$workdir/dbs.conf" <<'EOF'
[auto]
type = mysql
host = autohost
EOF
  run bash -c 'cd "'"$workdir"'" && export DB_OPS_TEST=1; . "'"$SCRIPT"'"; main help; echo "DB_HOST=$DB_HOST"'
  rm -rf "$workdir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DB_HOST=autohost"* ]]
}

@test "main behaves exactly like before (no config mechanism) when ./dbs.conf does not exist" {
  workdir="$(mktemp -d)"
  run bash -c 'cd "'"$workdir"'" && export DB_OPS_TEST=1; . "'"$SCRIPT"'"; main help --host clihost; echo "DB_HOST=$DB_HOST"'
  rmdir "$workdir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DB_HOST=clihost"* ]]
}

# ===================== --instance flag parsing =====================

@test "parse_common_args sets INSTANCE_NAME from --instance" {
  parse_common_args --instance myinst
  [ "$INSTANCE_NAME" = "myinst" ]
}

@test "parse_common_args dies with a clear error when --instance's value is missing" {
  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; parse_common_args --instance'
  [ "$status" -eq 1 ]
  [[ "$output" == *"--instance requires a value"* ]]
}

@test "extract_config_file dies with a clear error when --instance's value is missing" {
  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; extract_config_file --instance'
  [ "$status" -eq 1 ]
  [[ "$output" == *"--instance requires a value"* ]]
}

@test "main accepts --instance before the command, like other global options" {
  cfg="$(mktemp)"
  cat > "$cfg" <<'EOF'
[prod]
type = mysql
host = prodhost

[staging]
type = mysql
host = staginghost
EOF
  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; main --config "'"$cfg"'" --instance staging help; echo "DB_HOST=$DB_HOST"'
  rm -f "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DB_HOST=staginghost"* ]]
}

@test "main does not mistake --instance's value for the command word" {
  cfg="$(mktemp)"
  cat > "$cfg" <<'EOF'
[backup]
type = mysql
host = bkhost
EOF
  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; main --config "'"$cfg"'" --instance backup help; echo "DB_HOST=$DB_HOST"'
  rm -f "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DB_HOST=bkhost"* ]]
}
