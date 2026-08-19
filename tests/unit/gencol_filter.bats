#!/usr/bin/env bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../my-ops.sh"
  export DB_OPS_TEST=1
  # shellcheck disable=SC1090
  . "$SCRIPT"
}

@test "GENCOL_AWK_PROGRAM rewrites only the generated column in the column list, not VALUES" {
  data_sql="$(mktemp)"
  map_file="$(mktemp)"
  cat > "$data_sql" <<'EOF'
INSERT INTO `products` (`id`, `name`, `price`, `price_with_tax`, `name_upper`, `thumbnail`) VALUES (1,'Widget',9.99,10.99,'WIDGET',0x89504E47);
INSERT INTO `audit_log` (`id`, `message`) VALUES (1,'price_with_tax mentioned here, not a real column');
EOF
  printf 'products\tprice_with_tax\nproducts\tname_upper\n' > "$map_file"

  run gawk -v mapfile="$map_file" "$GENCOL_AWK_PROGRAM" "$data_sql"
  [ "$status" -eq 0 ]

  [[ "$output" == *'`products` (`id`, `name`, `price`, `price_with_tax_tmp`, `name_upper_tmp`, `thumbnail`) VALUES (1,'"'"'Widget'"'"',9.99,10.99,'"'"'WIDGET'"'"',0x89504E47)'* ]]
  [[ "$output" == *"price_with_tax mentioned here, not a real column"* ]]

  rm -f "$data_sql" "$map_file"
}

@test "GENCOL_AWK_PROGRAM leaves tables with no generated columns untouched" {
  data_sql="$(mktemp)"
  map_file="$(mktemp)"
  cat > "$data_sql" <<'EOF'
INSERT INTO `audit_log` (`id`, `message`) VALUES (1,'hello');
EOF
  : > "$map_file"

  run gawk -v mapfile="$map_file" "$GENCOL_AWK_PROGRAM" "$data_sql"
  [ "$status" -eq 0 ]
  [ "$output" = "INSERT INTO \`audit_log\` (\`id\`, \`message\`) VALUES (1,'hello');" ]

  rm -f "$data_sql" "$map_file"
}
