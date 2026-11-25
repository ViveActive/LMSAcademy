-- Laatste activiteit uit de ledenexport van Huddle (inloggen e.d.) als startpunt voor de status.
alter table members add column if not exists huddle_laatste_activiteit timestamptz;

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
         count(*) filter (where at > now() - interval '28 days' and kind <> 'huddle-export') as activiteit_4w
  from (select member_id, at, kind from activity
        union all
        select huddle_id, huddle_laatste_activiteit, 'huddle-export' from members
         where huddle_laatste_activiteit is not null) x
  group by member_id
),
qz as (
  select member_id, count(*) as quizpogingen,
         count(*) filter (where passed) as quiz_gehaald,
         avg(score) as gem_score
  from quiz_attempts group by member_id
),
ct as (
  select distinct on (member_id) member_id, issued_at, cert_valid_until(course_id, issued_at) as valid_until, name
  from certificates order by member_id, issued_at desc
),
ce as (
  select member_id,
         round(avg(voortgang_pct)) as voortgang,
         count(*) as opleidingen,
         count(*) filter (where certificaat_status in ('Behaald', 'Verloopt binnenkort')) as cert_behaald,
         count(*) filter (where certificaat_status in ('Open', 'Verlopen')) as cert_open
  from v_course_enrollment group by member_id
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
  coalesce(ce.voortgang,
           case when req.n > 0 and mp.member_id is not null then round(100.0 * coalesce(mp.verplicht_voltooid, 0) / req.n) end,
           case when req.n > 0 then 0 end) as voortgang_pct,
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
  end as certificaat_status,
  coalesce(ce.opleidingen, 0)  as opleidingen,
  coalesce(ce.cert_behaald, 0) as certificaten_behaald,
  coalesce(ce.cert_open, 0)    as certificaten_open
from members m
cross join req
left join mp  on mp.member_id = m.huddle_id
left join act a on a.member_id = m.huddle_id
left join qz  on qz.member_id = m.huddle_id
left join ct  on ct.member_id = m.huddle_id
left join ce  on ce.member_id = m.huddle_id
where m.deleted_at is null;

-- Certificaten die al zijn verwerkt krijgen de geldigheid van hun opleiding
update certificates set valid_until = cert_valid_until(course_id, issued_at) where course_id is not null;

alter view v_course_enrollment set (security_invoker = true);
alter view v_course_summary    set (security_invoker = true);
alter view v_member_status set (security_invoker = true);
