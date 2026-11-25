#!/usr/bin/env bash
# Draait de databasetests tegen een lokale Postgres (16+).
# Gebruik: PGHOST=... PGPORT=... PGUSER=postgres scripts/test-db.sh
set -euo pipefail
cd "$(dirname "$0")/.."
P="psql -q -v ON_ERROR_STOP=1"
$P -c "drop database if exists lms_test" -c "create database lms_test"
for f in test/supabase_stub.sql supabase/migrations/*.sql; do $P -d lms_test -f "$f" >/dev/null 2>&1; done
$P -d lms_test -f test/test_events.sql | grep -q "ALLE TESTS GESLAAGD" && echo "Databasetests geslaagd"
