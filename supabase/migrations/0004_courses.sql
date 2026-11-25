-- Opleidingen en te behalen certificaten.
-- Een opleiding is een cursus in Huddle. Per opleiding leg je vast welk certificaat
-- je ermee haalt en hoe lang dat geldig is. Modules horen bij een opleiding.

alter table courses add column if not exists certificate_name text;          -- bijv. 'Mastertrainer'
alter table courses add column if not exists cert_geldig_maanden int;        -- leeg = algemene instelling
alter table courses add column if not exists description text;
alter table courses add column if not exists position int;
alter table courses add column if not exists hidden boolean not null default false;

drop policy if exists admin_update on courses;
create policy admin_update on courses for update to authenticated using (is_admin()) with check (is_admin());
grant update on courses to authenticated;

-- Geldigheid per opleiding gebruiken waar die is ingesteld
create or replace function cert_valid_until(p_course_id text, p_issued timestamptz) returns timestamptz
language sql stable as $$
  select p_issued + make_interval(months => coalesce(
    (select cert_geldig_maanden from courses where id = p_course_id),
    setting_int('cert_geldig_maanden')))
$$;

-- ---------------------------------------------------------------------------
-- Per lid per opleiding
-- ---------------------------------------------------------------------------
create or replace view v_course_enrollment as
with req as (
  select course_id, count(*) as n from modules where required and course_id is not null group by course_id
),
per as (
  select mp.member_id, m.course_id,
         min(mp.started_at) as eerste_module,
         count(*) filter (where mp.completed_at is not null and m.required) as verplicht_voltooid,
         count(*) filter (where mp.completed_at is null and mp.started_at is not null) as open_modules,
         max(greatest(mp.started_at, mp.completed_at)) as laatste_module
  from module_progress mp join modules m on m.id = mp.module_id
  where m.course_id is not null
  group by mp.member_id, m.course_id
),
enr as (
  select member_id, course_id from per
  union
  select member_id, course_id from course_progress
  union
  select member_id, course_id from certificates where course_id is not null
),
cert as (
  select distinct on (member_id, course_id) member_id, course_id, issued_at,
         cert_valid_until(course_id, issued_at) as valid_until
  from certificates where course_id is not null
  order by member_id, course_id, issued_at desc
),
lastact as (
  select member_id, max(at) as at from activity group by member_id
)
select
  e.member_id, e.course_id, c.name as opleiding, c.certificate_name,
  least(cp.started_at, p.eerste_module) as gestart_op,
  cp.completed_at as afgerond_op,
  coalesce(r.n, 0) as verplichte_modules,
  coalesce(p.verplicht_voltooid, 0) as modules_voltooid,
  coalesce(p.open_modules, 0) as modules_open,
  case when r.n > 0 then round(100.0 * coalesce(p.verplicht_voltooid, 0) / r.n)
       when cp.completed_at is not null then 100 end as voortgang_pct,
  case
    when cp.completed_at is not null or (r.n > 0 and p.verplicht_voltooid >= r.n) then 'Afgerond'
    when coalesce(la.at, p.laatste_module, cp.started_at) < now() - make_interval(days => setting_int('vastgelopen_dagen')) then 'Vastgelopen'
    else 'Bezig'
  end as opleiding_status,
  ct.issued_at as certificaat_datum,
  ct.valid_until as certificaat_geldig_tot,
  case
    when c.certificate_name is null and ct.issued_at is null then 'Geen certificaat'
    when ct.issued_at is null then 'Open'
    when ct.valid_until < now() then 'Verlopen'
    when ct.valid_until < now() + make_interval(months => setting_int('cert_signaal_maanden')) then 'Verloopt binnenkort'
    else 'Behaald'
  end as certificaat_status
from enr e
join courses c on c.id = e.course_id and not c.hidden
join members mb on mb.huddle_id = e.member_id and mb.deleted_at is null
left join course_progress cp on cp.member_id = e.member_id and cp.course_id = e.course_id
left join per p on p.member_id = e.member_id and p.course_id = e.course_id
left join req r on r.course_id = e.course_id
left join cert ct on ct.member_id = e.member_id and ct.course_id = e.course_id
left join lastact la on la.member_id = e.member_id;

-- ---------------------------------------------------------------------------
-- Per opleiding
-- ---------------------------------------------------------------------------
create or replace view v_course_summary as
select
  c.id as course_id, c.name as opleiding, c.certificate_name, c.description, c.position,
  coalesce(c.cert_geldig_maanden, setting_int('cert_geldig_maanden')) as cert_geldig_maanden,
  (select count(*) from modules m where m.course_id = c.id and m.required) as verplichte_modules,
  count(e.member_id) as ingeschreven,
  count(*) filter (where e.opleiding_status = 'Bezig')       as bezig,
  count(*) filter (where e.opleiding_status = 'Vastgelopen') as vastgelopen,
  count(*) filter (where e.opleiding_status = 'Afgerond')    as afgerond,
  round(avg(e.voortgang_pct)) as gem_voortgang,
  count(*) filter (where e.certificaat_status in ('Behaald', 'Verloopt binnenkort')) as gecertificeerd,
  count(*) filter (where e.certificaat_status = 'Verloopt binnenkort') as cert_verloopt,
  count(*) filter (where e.certificaat_status = 'Verlopen') as cert_verlopen,
  count(*) filter (where e.certificaat_status = 'Open') as cert_open
from courses c
left join v_course_enrollment e on e.course_id = c.id
where not c.hidden
group by c.id;

-- ---------------------------------------------------------------------------
-- Lidstatus: voortgang = gemiddelde over de opleidingen waarin iemand zit,
-- plus tellingen van certificaten. Kolommen achteraan toegevoegd.
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
alter view v_member_status     set (security_invoker = true);
revoke all on v_course_enrollment, v_course_summary from anon;
grant select on v_course_enrollment, v_course_summary to authenticated;
