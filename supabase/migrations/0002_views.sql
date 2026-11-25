-- Rapportageviews: totaal, per groep en per lid.
-- "Activiteit" = leergebeurtenis die Huddle via een webhook meldt (zie tabel activity).

-- ---------------------------------------------------------------------------
-- Per lid
-- ---------------------------------------------------------------------------
create or replace view v_member_status as
with req as (
  select count(*) as n from modules where required
),
mp as (
  select mp.member_id,
         count(*) filter (where mp.started_at is not null)   as modules_gestart,
         count(*) filter (where mp.completed_at is not null) as modules_voltooid,
         count(*) filter (where mp.completed_at is not null and m.required) as verplicht_voltooid,
         count(*) filter (where mp.completed_at is null and mp.started_at is not null) as modules_open
  from module_progress mp join modules m on m.id = mp.module_id
  group by mp.member_id
),
act as (
  select member_id, max(at) as laatst_actief,
         count(*) filter (where at > now() - interval '28 days') as activiteit_4w
  from activity group by member_id
),
qz as (
  select member_id, count(*) as quizpogingen,
         count(*) filter (where passed) as quiz_gehaald,
         avg(score) as gem_score
  from quiz_attempts group by member_id
),
ct as (
  select distinct on (member_id) member_id, issued_at, valid_until, name
  from certificates order by member_id, issued_at desc
)
select
  m.huddle_id,
  m.email,
  trim(coalesce(m.first_name, '') || ' ' || coalesce(m.last_name, '')) as naam,
  m.created_at,
  m.first_login_at,
  m.measured_since,
  (select string_agg(g.name, ', ' order by g.name)
     from memberships ms join groups g on g.id = ms.group_id
    where ms.member_id = m.huddle_id and ms.until is null and not g.hidden) as groepen,
  a.laatst_actief,
  extract(day from now() - a.laatst_actief)::int as dagen_inactief,
  coalesce(a.activiteit_4w, 0) as activiteit_4w,
  case
    when a.laatst_actief is null and m.first_login_at is null then 'Nooit actief'
    when a.laatst_actief is null then 'Uitgevallen'
    when a.laatst_actief > now() - make_interval(days => setting_int('actief_dagen'))   then 'Actief'
    when a.laatst_actief > now() - make_interval(days => setting_int('afnemend_dagen')) then 'Afnemend'
    when a.laatst_actief > now() - make_interval(days => setting_int('inactief_dagen')) then 'Inactief'
    else 'Uitgevallen'
  end as status,
  coalesce(mp.modules_gestart, 0)  as modules_gestart,
  coalesce(mp.modules_voltooid, 0) as modules_voltooid,
  coalesce(mp.modules_open, 0)     as modules_open,
  case when req.n > 0 then round(100.0 * coalesce(mp.verplicht_voltooid, 0) / req.n) end as voortgang_pct,
  coalesce(qz.quizpogingen, 0) as quizpogingen,
  coalesce(qz.quiz_gehaald, 0) as quiz_gehaald,
  case when qz.quizpogingen > 0 then round(100.0 * qz.quiz_gehaald / qz.quizpogingen) end as quiz_slagingspct,
  round(qz.gem_score, 1) as gem_quizscore,
  ct.issued_at   as certificaat_datum,
  ct.valid_until as certificaat_geldig_tot,
  case
    when ct.issued_at is null then 'Geen'
    when ct.valid_until < now() then 'Verlopen'
    when ct.valid_until < now() + make_interval(months => setting_int('cert_signaal_maanden')) then 'Verloopt binnenkort'
    else 'Geldig'
  end as certificaat_status
from members m
cross join req
left join mp  on mp.member_id = m.huddle_id
left join act a on a.member_id = m.huddle_id
left join qz  on qz.member_id = m.huddle_id
left join ct  on ct.member_id = m.huddle_id
where m.deleted_at is null;

-- ---------------------------------------------------------------------------
-- Per groep
-- ---------------------------------------------------------------------------
create or replace view v_group_summary as
select
  g.id as group_id, g.name, g.kind, g.coach,
  count(s.huddle_id) as leden,
  count(*) filter (where s.status = 'Actief')      as actief,
  count(*) filter (where s.status = 'Afnemend')    as afnemend,
  count(*) filter (where s.status = 'Inactief')    as inactief,
  count(*) filter (where s.status in ('Uitgevallen', 'Nooit actief')) as uitgevallen,
  round(avg(s.voortgang_pct)) as gem_voortgang,
  count(*) filter (where s.certificaat_status in ('Geldig', 'Verloopt binnenkort')) as gecertificeerd,
  count(*) filter (where s.certificaat_status = 'Verloopt binnenkort') as cert_verloopt,
  round(100.0 * sum(s.quiz_gehaald) / nullif(sum(s.quizpogingen), 0)) as quiz_slagingspct
from groups g
left join memberships ms on ms.group_id = g.id and ms.until is null
left join v_member_status s on s.huddle_id = ms.member_id
where not g.hidden
group by g.id, g.name, g.kind, g.coach;

-- ---------------------------------------------------------------------------
-- Totaal
-- ---------------------------------------------------------------------------
create or replace view v_totals as
select
  count(*) as leden,
  count(*) filter (where status = 'Actief')   as actief,
  count(*) filter (where status = 'Afnemend') as afnemend,
  count(*) filter (where status = 'Inactief') as inactief,
  count(*) filter (where status = 'Uitgevallen') as uitgevallen,
  count(*) filter (where status = 'Nooit actief') as nooit_actief,
  round(avg(voortgang_pct)) as gem_voortgang,
  count(*) filter (where certificaat_status in ('Geldig', 'Verloopt binnenkort')) as gecertificeerd,
  count(*) filter (where certificaat_status = 'Verloopt binnenkort') as cert_verloopt,
  round(100.0 * sum(quiz_gehaald) / nullif(sum(quizpogingen), 0)) as quiz_slagingspct,
  min(measured_since) as gemeten_sinds
from v_member_status;

-- ---------------------------------------------------------------------------
-- Modules: waar haken mensen af (optioneel per groep te filteren in de app)
-- ---------------------------------------------------------------------------
create or replace view v_module_progress as
select
  mp.member_id, ms.group_id, m.id as module_id, m.name as module, m.required, m.position,
  c.name as cursus,
  mp.started_at, mp.completed_at,
  (mp.completed_at is null and mp.started_at is not null and
   coalesce((select max(at) from activity a where a.member_id = mp.member_id), mp.started_at)
     < now() - make_interval(days => setting_int('vastgelopen_dagen'))) as vastgelopen
from module_progress mp
join modules m on m.id = mp.module_id
left join courses c on c.id = m.course_id
left join memberships ms on ms.member_id = mp.member_id and ms.until is null
join members mb on mb.huddle_id = mp.member_id and mb.deleted_at is null;

create or replace view v_module_funnel as
select m.id as module_id, m.name as module, m.required, m.position, c.name as cursus,
       count(distinct mp.member_id) filter (where mp.started_at is not null)   as gestart,
       count(distinct mp.member_id) filter (where mp.completed_at is not null) as voltooid,
       count(distinct mp.member_id) filter (where mp.vastgelopen)              as vastgelopen
from modules m
left join courses c on c.id = m.course_id
left join v_module_progress mp on mp.module_id = m.id
group by m.id, m.name, m.required, m.position, c.name;

-- ---------------------------------------------------------------------------
-- Activiteit per week (laatste 12 weken), per lid
-- ---------------------------------------------------------------------------
create or replace view v_weekly_activity as
select a.member_id, date_trunc('week', a.at)::date as week, count(*) as gebeurtenissen
from activity a
where a.at > date_trunc('week', now()) - interval '11 weeks'
group by a.member_id, date_trunc('week', a.at);

-- Tijdlijn per lid (laatste gebeurtenissen)
create or replace view v_member_timeline as
select a.member_id, a.at, a.kind,
       coalesce(e.payload #>> '{module,name}', e.payload #>> '{quiz,name}',
                e.payload #>> '{course,name}', e.payload #>> '{certificate,name}') as onderwerp
from activity a join huddle_events e on e.id = a.event_id;
