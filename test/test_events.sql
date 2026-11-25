-- Test: verwerk voorbeeldberichten en controleer de rapportageviews.
-- Draait in een transactie en laat niets achter.
\set ON_ERROR_STOP on
begin;

insert into admins values ('beheer@example.org', 'test');
update modules set required = true;

-- Startpositie via CSV-import (lid zonder Huddle-id)
select import_members('lvl-mt', 'Mastertrainers 2026',
  '[{"email":"Anna@Example.org","firstname":"Anna","lastname":"de Boer"},
    {"email":"bram@example.org","firstname":"Bram","lastname":"Smit"},
    {"email":"chris@example.org","firstname":"Chris","lastname":"Jansen"}]'::jsonb) as geimporteerd;

-- Webhooks (vorm volgens Huddle-documentatie; tijdstempel meegegeven voor de test)
select ingest_event('user_onboarded', jsonb_build_object('trigger_type','user_onboarded','tenant_id','t1',
  'timestamp', now() - interval '40 days',
  'user', jsonb_build_object('id','u1','firstname','Anna','lastname','de Boer','fullname','Anna de Boer','email','anna@example.org')));

select ingest_event(tt, jsonb_build_object('trigger_type', tt, 'tenant_id','t1', 'timestamp', ts,
  'user', jsonb_build_object('id', uid, 'firstname', fn, 'email', em),
  'course', jsonb_build_object('id','c1','name','Mastertrainer opleiding'),
  'module', jsonb_build_object('id', mid, 'name', mname)))
from (values
  ('module_started',   now() - interval '35 days', 'u1','Anna','anna@example.org','m1','Basis didactiek'),
  ('module_completed', now() - interval '20 days', 'u1','Anna','anna@example.org','m1','Basis didactiek'),
  ('module_started',   now() - interval '5 days',  'u1','Anna','anna@example.org','m2','Trainingsopbouw'),
  ('module_started',   now() - interval '50 days', 'u2','Bram','bram@example.org','m1','Basis didactiek'),
  ('module_started',   now() - interval '3 days',  'u4','Dirk','dirk@example.org','m1','Basis didactiek'),
  ('module_completed', now() - interval '2 days',  'u4','Dirk','dirk@example.org','m1','Basis didactiek'),
  ('module_started',   now() - interval '2 days',  'u4','Dirk','dirk@example.org','m2','Trainingsopbouw'),
  ('module_completed', now() - interval '1 days',  'u4','Dirk','dirk@example.org','m2','Trainingsopbouw')
) v(tt, ts, uid, fn, em, mid, mname);

select ingest_event('quiz_passed', jsonb_build_object('trigger_type','quiz_passed','timestamp', now() - interval '1 day',
  'user', jsonb_build_object('id','u4','email','dirk@example.org'),
  'course', jsonb_build_object('id','c1','name','Mastertrainer opleiding'),
  'quiz', jsonb_build_object('id','q1','name','Eindtoets')));
select ingest_event('quiz_failed', jsonb_build_object('trigger_type','quiz_failed','timestamp', now() - interval '6 day',
  'user', jsonb_build_object('id','u1','email','anna@example.org'),
  'quiz', jsonb_build_object('id','q1','name','Eindtoets')));
select ingest_event('certificate_sent', jsonb_build_object('trigger_type','certificate_sent','timestamp', now() - interval '1 day',
  'user', jsonb_build_object('id','u4','email','dirk@example.org'),
  'course', jsonb_build_object('id','c1','name','Mastertrainer opleiding'),
  'certificate', jsonb_build_object('id','cert1','name','Mastertrainer')));
select ingest_event('access_level_added', jsonb_build_object('trigger_type','access_level_added',
  'user', jsonb_build_object('id','u4','email','dirk@example.org'),
  'access_level', jsonb_build_object('id','lvl-ct','name','Clubtrainers Noord')));

-- Dubbel bericht wordt genegeerd
select ingest_event('certificate_sent', payload) is null as dubbel_genegeerd
  from huddle_events where trigger_type = 'certificate_sent';

-- Controles
do $$
declare r record;
begin
  -- CSV-lid Anna kreeg haar Huddle-id
  perform 1 from members where huddle_id = 'u1' and email = 'anna@example.org';
  if not found then raise exception 'CSV-lid niet gekoppeld aan Huddle-id'; end if;
  if exists (select 1 from members where huddle_id like 'email:anna%') then raise exception 'dubbel lid Anna'; end if;
  -- Anna nog in groep na id-wissel
  perform 1 from memberships where member_id = 'u1' and group_id = 'lvl-mt';
  if not found then raise exception 'lidmaatschap verloren bij id-wissel'; end if;

  select * into r from v_member_status where huddle_id = 'u1';
  if r.status <> 'Actief' then raise exception 'Anna status %', r.status; end if;
  if r.voortgang_pct <> 50 then raise exception 'Anna voortgang %', r.voortgang_pct; end if;

  select * into r from v_member_status where huddle_id = 'u2';
  if r.status <> 'Inactief' then raise exception 'Bram status %', r.status; end if;

  select * into r from v_member_status where email = 'chris@example.org';
  if r.status <> 'Nooit actief' then raise exception 'Chris status %', r.status; end if;

  select * into r from v_member_status where huddle_id = 'u4';
  if r.certificaat_status <> 'Geldig' or r.voortgang_pct <> 100 or r.quiz_slagingspct <> 100 then
    raise exception 'Dirk: % % %', r.certificaat_status, r.voortgang_pct, r.quiz_slagingspct; end if;
  if r.groepen <> 'Clubtrainers Noord' then raise exception 'Dirk groep %', r.groepen; end if;

  select * into r from v_totals;
  if r.leden <> 4 or r.actief <> 2 or r.gecertificeerd <> 1 then
    raise exception 'totaal: leden % actief % cert %', r.leden, r.actief, r.gecertificeerd; end if;

  select * into r from v_module_funnel where module_id = 'm1';
  if r.gestart <> 3 or r.voltooid <> 2 or r.vastgelopen <> 1 then
    raise exception 'funnel m1: % % %', r.gestart, r.voltooid, r.vastgelopen; end if;

  select * into r from v_group_summary where group_id = 'lvl-mt';
  if r.leden <> 3 then raise exception 'groep MT leden %', r.leden; end if;

  if exists (select 1 from huddle_events where error is not null) then
    raise exception 'verwerkingsfout: %', (select error from huddle_events where error is not null limit 1); end if;
end $$;

-- RLS: niet-beheerder ziet niets, beheerder wel, anon heeft geen toegang
set local role authenticated;
select set_config('request.jwt.claims', '{"email":"iemand@example.org"}', true);
do $$ begin
  if (select count(*) from v_member_status) <> 0 then raise exception 'RLS lek voor niet-beheerder'; end if;
end $$;
select set_config('request.jwt.claims', '{"email":"Beheer@example.org"}', true);
do $$ begin
  if (select leden from v_totals) <> 4 then raise exception 'beheerder ziet niet alles'; end if;
end $$;
reset role;

select 'ALLE TESTS GESLAAGD' as resultaat;
rollback;
