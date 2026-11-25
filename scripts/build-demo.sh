#!/usr/bin/env bash
# Bouwt dashboard/demo-data.json uit verzonnen voorbeelddata in een lokale Postgres.
# Gebruik: PGHOST=... PGPORT=... PGUSER=postgres scripts/build-demo.sh
set -euo pipefail
cd "$(dirname "$0")/.."
P="psql -q -v ON_ERROR_STOP=1"
$P -c "drop database if exists lms_demo" -c "create database lms_demo"
for f in test/supabase_stub.sql supabase/migrations/*.sql test/seed_demo.sql; do $P -d lms_demo -f "$f" >/dev/null 2>&1 || { $P -d lms_demo -f "$f"; exit 1; }; done
psql -qAt -d lms_demo -c "select json_build_object(
 'generated', now(),
 'v_totals', (select json_agg(t) from v_totals t),
 'v_group_summary', (select json_agg(t) from v_group_summary t),
 'v_member_status', (select json_agg(t) from v_member_status t),
 'v_module_progress', (select json_agg(t) from v_module_progress t),
 'v_module_funnel', (select json_agg(t) from v_module_funnel t),
 'v_weekly_activity', (select json_agg(t) from v_weekly_activity t),
 'v_member_timeline', (select json_agg(t) from v_member_timeline t),
 'v_course_enrollment', (select json_agg(t) from v_course_enrollment t),
 'v_course_summary', (select json_agg(t) from v_course_summary t),
 'courses', (select json_agg(t) from courses t),
 'memberships', (select json_agg(t) from memberships t where until is null),
 'groups', (select json_agg(t) from groups t),
 'modules', (select json_agg(t) from modules t),
 'settings', (select json_agg(t) from settings t))" > dashboard/demo-data.json
echo "dashboard/demo-data.json bijgewerkt"
