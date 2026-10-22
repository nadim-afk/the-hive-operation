#!/usr/bin/env bash
# Usage: ./scripts_run_db_tests.sh   (needs a local Postgres with superuser access via `psql`)
set -euo pipefail
DB=ems_test; psql -q -c "drop database if exists $DB" -c "create database $DB"
psql -q -v ON_ERROR_STOP=1 -d $DB -f supabase/tests/stub_supabase.sql
for f in supabase/migrations/*.sql; do psql -q -v ON_ERROR_STOP=1 -d $DB -f "$f"; done
psql -q -v ON_ERROR_STOP=1 -d $DB -f supabase/tests/behavior.sql 2>&1 | grep -E "PASS|FAIL|ERROR"
