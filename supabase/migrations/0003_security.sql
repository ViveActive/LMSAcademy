-- Toegang: alleen beheerders (e-mailadres in tabel admins) mogen data lezen.
-- De webhook-functie en imports gebruiken de service-role sleutel en lopen buiten RLS om.

create table if not exists admins (
  email text primary key,
  note  text
);

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from admins
     where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  )
$$;

do $$
declare t text;
begin
  foreach t in array array['settings','huddle_events','members','groups','memberships','courses',
                           'modules','course_progress','module_progress','quiz_attempts',
                           'certificates','activity','admins']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists admin_read on %I', t);
    execute format('create policy admin_read on %I for select to authenticated using (is_admin())', t);
    execute format('revoke all on %I from anon', t);
  end loop;
end $$;

-- Beheerders mogen groepen en modules bijwerken (naam, type, begeleider, verplicht, volgorde)
drop policy if exists admin_update on groups;
create policy admin_update on groups for update to authenticated using (is_admin()) with check (is_admin());
drop policy if exists admin_update on modules;
create policy admin_update on modules for update to authenticated using (is_admin()) with check (is_admin());
drop policy if exists admin_update on settings;
create policy admin_update on settings for update to authenticated using (is_admin()) with check (is_admin());
grant update on groups, modules, settings to authenticated;

-- Views draaien met de rechten van de lezer, zodat RLS hierboven geldt
alter view v_member_status   set (security_invoker = true);
alter view v_group_summary   set (security_invoker = true);
alter view v_totals          set (security_invoker = true);
alter view v_module_progress set (security_invoker = true);
alter view v_module_funnel   set (security_invoker = true);
alter view v_weekly_activity set (security_invoker = true);
alter view v_member_timeline set (security_invoker = true);

revoke all on v_member_status, v_group_summary, v_totals, v_module_progress,
              v_module_funnel, v_weekly_activity, v_member_timeline from anon;
grant select on v_member_status, v_group_summary, v_totals, v_module_progress,
                v_module_funnel, v_weekly_activity, v_member_timeline to authenticated;

-- Schrijvende functies alleen voor de service role
revoke execute on function ingest_event(text, jsonb)          from public, anon, authenticated;
revoke execute on function import_members(text, text, jsonb)  from public, anon, authenticated;
revoke execute on function reprocess_all()                    from public, anon, authenticated;
revoke execute on function process_event(bigint)              from public, anon, authenticated;
grant execute on function ingest_event(text, jsonb)          to service_role;
grant execute on function import_members(text, text, jsonb)  to service_role;
grant execute on function reprocess_all()                    to service_role;
