-- Rapportage naast The Huddle: schema
-- Alle webhookberichten worden eerst onbewerkt bewaard (huddle_events) en daarna
-- verwerkt in overzichtstabellen. Opnieuw verwerken kan altijd met reprocess_all().

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Instellingen (statusgrenzen e.d.), aan te passen zonder code te wijzigen
-- ---------------------------------------------------------------------------
create table if not exists settings (
  key   text primary key,
  value text not null,
  note  text
);

insert into settings (key, value, note) values
  ('actief_dagen',      '14', 'Actief = leergebeurtenis in de laatste N dagen'),
  ('afnemend_dagen',    '30', 'Afnemend = tussen actief_dagen en N dagen'),
  ('inactief_dagen',    '60', 'Inactief = tussen afnemend_dagen en N dagen; daarna uitgevallen'),
  ('vastgelopen_dagen', '30', 'Module gestart, niet voltooid en N dagen geen activiteit'),
  ('cert_geldig_maanden', '24', 'Geldigheid certificaat'),
  ('cert_signaal_maanden', '3', 'Signaal N maanden voor het certificaat verloopt')
on conflict (key) do nothing;

create or replace function setting_int(k text) returns int
language sql stable as $$ select value::int from settings where key = k $$;

-- ---------------------------------------------------------------------------
-- Ruwe gebeurtenissen
-- ---------------------------------------------------------------------------
create table if not exists huddle_events (
  id           bigserial primary key,
  received_at  timestamptz not null default now(),
  trigger_type text not null,
  payload      jsonb not null,
  dedupe_key   text not null unique,   -- hash van de payload: dubbele berichten worden genegeerd
  processed_at timestamptz,
  error        text
);
create index if not exists huddle_events_trigger_idx on huddle_events (trigger_type, received_at);

-- ---------------------------------------------------------------------------
-- Overzichtstabellen
-- ---------------------------------------------------------------------------
create table if not exists members (
  huddle_id      text primary key,          -- id uit Huddle, of 'email:<adres>' bij CSV-import zonder id
  email          text,
  first_name     text,
  last_name      text,
  created_at     timestamptz,
  first_login_at timestamptz,
  deleted_at     timestamptz,
  measured_since timestamptz not null default now()  -- vanaf wanneer we gebeurtenissen ontvangen
);
create unique index if not exists members_email_idx on members (lower(email)) where email is not null;

create table if not exists groups (
  id    text primary key,                    -- id of naam van het toegangsniveau in Huddle
  name  text not null,
  kind  text,                                -- bijv. 'Mastertrainers' of 'Clubtrainers'
  coach text,
  hidden boolean not null default false      -- niveaus die geen groep zijn (bijv. 'Betaald') verbergen
);

create table if not exists memberships (
  member_id text not null references members(huddle_id) on delete cascade on update cascade,
  group_id  text not null references groups(id) on delete cascade,
  since     timestamptz not null default now(),
  until     timestamptz,
  primary key (member_id, group_id, since)
);

create table if not exists courses (
  id   text primary key,
  name text not null
);

create table if not exists modules (
  id        text primary key,
  course_id text references courses(id),
  name      text not null,
  required  boolean not null default true,   -- telt mee voor voortgang en certificering
  position  int
);

create table if not exists course_progress (
  member_id    text not null references members(huddle_id) on delete cascade on update cascade,
  course_id    text not null references courses(id),
  started_at   timestamptz,
  completed_at timestamptz,
  primary key (member_id, course_id)
);

create table if not exists module_progress (
  member_id    text not null references members(huddle_id) on delete cascade on update cascade,
  module_id    text not null references modules(id),
  started_at   timestamptz,
  completed_at timestamptz,
  primary key (member_id, module_id)
);

create table if not exists quiz_attempts (
  id        bigserial primary key,
  event_id  bigint unique references huddle_events(id) on delete cascade,
  member_id text not null references members(huddle_id) on delete cascade on update cascade,
  quiz_id   text,
  quiz_name text,
  course_id text references courses(id),
  module_id text references modules(id),
  passed    boolean not null,
  score     numeric,                          -- alleen als Huddle een score meestuurt
  at        timestamptz not null
);

create table if not exists certificates (
  id          bigserial primary key,
  event_id    bigint unique references huddle_events(id) on delete cascade,
  member_id   text not null references members(huddle_id) on delete cascade on update cascade,
  course_id   text references courses(id),
  name        text,
  issued_at   timestamptz not null,
  valid_until timestamptz
);

-- Elke gebeurtenis die als 'activiteit' telt, per lid
create table if not exists activity (
  event_id  bigint primary key references huddle_events(id) on delete cascade,
  member_id text not null references members(huddle_id) on delete cascade on update cascade,
  kind      text not null,
  at        timestamptz not null
);
create index if not exists activity_member_idx on activity (member_id, at);

-- ---------------------------------------------------------------------------
-- Hulpfuncties om velden defensief uit de payload te halen
-- (de exacte veldnamen van Huddle zijn niet volledig gedocumenteerd)
-- ---------------------------------------------------------------------------
create or replace function j_text(obj jsonb, variadic keys text[]) returns text
language plpgsql immutable as $$
declare k text; v text;
begin
  if obj is null or jsonb_typeof(obj) <> 'object' then return null; end if;
  foreach k in array keys loop
    v := obj ->> k;
    if v is not null and v <> '' then return v; end if;
  end loop;
  return null;
end $$;

create or replace function event_time(p jsonb, fallback timestamptz) returns timestamptz
language plpgsql immutable as $$
declare t text;
begin
  t := j_text(p, 'timestamp', 'created_at', 'occurred_at', 'date');
  if t is null then return fallback; end if;
  begin
    return t::timestamptz;
  exception when others then
    return fallback;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- Verwerking van één gebeurtenis
-- ---------------------------------------------------------------------------
create or replace function process_event(p_event_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare
  ev       huddle_events%rowtype;
  p        jsonb;
  t        text;
  at       timestamptz;
  u        jsonb;
  m_id     text;
  c        jsonb; c_id text;
  md       jsonb; md_id text;
  q        jsonb;
  cert     jsonb;
  lvl      jsonb; lvl_id text; lvl_name text;
begin
  select * into ev from huddle_events where id = p_event_id;
  if not found then return; end if;
  p  := ev.payload;
  t  := lower(ev.trigger_type);
  at := event_time(p, ev.received_at);

  -- Lid
  u := p -> 'user';
  m_id := j_text(u, 'id', 'user_id', 'uuid');
  if m_id is null and j_text(u, 'email') is not null then
    m_id := 'email:' || lower(j_text(u, 'email'));
  end if;

  if m_id is not null then
    -- Een lid dat eerder via CSV (op e-mail) is ingelezen krijgt nu zijn echte Huddle-id
    if left(m_id, 6) <> 'email:' and j_text(u, 'email') is not null then
      update members set huddle_id = m_id
       where huddle_id = 'email:' || lower(j_text(u, 'email'))
         and not exists (select 1 from members where huddle_id = m_id);
    end if;

    insert into members (huddle_id, email, first_name, last_name, created_at, measured_since)
    values (m_id, lower(j_text(u, 'email')), j_text(u, 'firstname', 'first_name', 'voornaam'),
            j_text(u, 'lastname', 'last_name', 'achternaam'),
            case when t in ('user_created') then at end, at)
    on conflict (huddle_id) do update set
      email      = coalesce(excluded.email, members.email),
      first_name = coalesce(excluded.first_name, members.first_name),
      last_name  = coalesce(excluded.last_name, members.last_name),
      created_at = coalesce(members.created_at, excluded.created_at),
      measured_since = least(members.measured_since, excluded.measured_since);
  end if;

  if m_id is null then
    update huddle_events set processed_at = now(), error = 'geen gebruiker in payload' where id = p_event_id;
    return;
  end if;

  -- Cursus en module (worden aangemaakt zodra ze voor het eerst langskomen)
  c := p -> 'course';
  c_id := j_text(c, 'id', 'uuid');
  if c_id is not null then
    insert into courses (id, name) values (c_id, coalesce(j_text(c, 'name', 'title'), 'Cursus ' || c_id))
    on conflict (id) do update set name = coalesce(j_text(c, 'name', 'title'), courses.name);
  end if;

  md := p -> 'module';
  md_id := j_text(md, 'id', 'uuid');
  if md_id is not null then
    insert into modules (id, course_id, name, position)
    values (md_id, c_id, coalesce(j_text(md, 'name', 'title'), 'Module ' || md_id),
            nullif(j_text(md, 'position', 'order', 'sort'), '')::int)
    on conflict (id) do update set
      name = coalesce(j_text(md, 'name', 'title'), modules.name),
      course_id = coalesce(modules.course_id, excluded.course_id),
      position = coalesce(excluded.position, modules.position);
  end if;

  -- Per triggertype
  if t = 'user_created' then
    null; -- al afgehandeld hierboven
  elsif t in ('user_deleted') then
    update members set deleted_at = at where huddle_id = m_id;
  elsif t in ('user_onboarded', 'user_first_login', 'first_login') then
    update members set first_login_at = coalesce(first_login_at, at) where huddle_id = m_id;
    insert into activity values (p_event_id, m_id, 'eerste login', at) on conflict do nothing;

  elsif t = 'course_started' and c_id is not null then
    insert into course_progress (member_id, course_id, started_at) values (m_id, c_id, at)
    on conflict (member_id, course_id) do update set started_at = least(course_progress.started_at, excluded.started_at);
    insert into activity values (p_event_id, m_id, 'cursus gestart', at) on conflict do nothing;
  elsif t = 'course_completed' and c_id is not null then
    insert into course_progress (member_id, course_id, started_at, completed_at) values (m_id, c_id, at, at)
    on conflict (member_id, course_id) do update set completed_at = coalesce(course_progress.completed_at, excluded.completed_at);
    insert into activity values (p_event_id, m_id, 'cursus voltooid', at) on conflict do nothing;

  elsif t = 'module_started' and md_id is not null then
    insert into module_progress (member_id, module_id, started_at) values (m_id, md_id, at)
    on conflict (member_id, module_id) do update set started_at = least(module_progress.started_at, excluded.started_at);
    insert into activity values (p_event_id, m_id, 'module gestart', at) on conflict do nothing;
  elsif t = 'module_completed' and md_id is not null then
    insert into module_progress (member_id, module_id, started_at, completed_at) values (m_id, md_id, at, at)
    on conflict (member_id, module_id) do update set
      started_at = coalesce(module_progress.started_at, excluded.started_at),
      completed_at = coalesce(module_progress.completed_at, excluded.completed_at);
    insert into activity values (p_event_id, m_id, 'module voltooid', at) on conflict do nothing;

  elsif t in ('quiz_passed', 'quiz_failed') then
    q := p -> 'quiz';
    insert into quiz_attempts (event_id, member_id, quiz_id, quiz_name, course_id, module_id, passed, score, at)
    values (p_event_id, m_id, j_text(q, 'id', 'uuid'), j_text(q, 'name', 'title'), c_id, md_id,
            t = 'quiz_passed',
            case when j_text(q, 'score', 'percentage', 'result') ~ '^[0-9]+(\.[0-9]+)?$'
                 then j_text(q, 'score', 'percentage', 'result')::numeric end,
            at)
    on conflict (event_id) do nothing;
    insert into activity values (p_event_id, m_id, case when t = 'quiz_passed' then 'quiz gehaald' else 'quiz niet gehaald' end, at)
    on conflict do nothing;

  elsif t in ('certificate_sent', 'certificate_issued') then
    cert := p -> 'certificate';
    insert into certificates (event_id, member_id, course_id, name, issued_at, valid_until)
    values (p_event_id, m_id, c_id, coalesce(j_text(cert, 'name', 'title'), j_text(c, 'name', 'title')), at,
            at + make_interval(months => setting_int('cert_geldig_maanden')))
    on conflict (event_id) do nothing;
    insert into activity values (p_event_id, m_id, 'certificaat', at) on conflict do nothing;

  elsif t like '%access%' or t like '%level%' and t not like '%leveled%' then
    -- Toegangsniveau toegevoegd / verwijderd / verlopen. Objectnaam niet gedocumenteerd: probeer varianten.
    lvl := coalesce(p -> 'access_level', p -> 'accessLevel', p -> 'level', p -> 'toegangsniveau');
    lvl_id := j_text(lvl, 'id', 'uuid', 'name');
    lvl_name := coalesce(j_text(lvl, 'name', 'title'), lvl_id);
    if lvl_id is not null then
      insert into groups (id, name) values (lvl_id, lvl_name)
      on conflict (id) do update set name = coalesce(lvl_name, groups.name);
      if t like '%removed%' or t like '%expired%' or t like '%deleted%' then
        update memberships set until = at
         where member_id = m_id and group_id = lvl_id and until is null;
      else
        insert into memberships (member_id, group_id, since)
        select m_id, lvl_id, at
         where not exists (select 1 from memberships where member_id = m_id and group_id = lvl_id and until is null);
      end if;
    end if;
  end if;

  update huddle_events set processed_at = now(), error = null where id = p_event_id;
exception when others then
  update huddle_events set processed_at = now(), error = sqlerrm where id = p_event_id;
end $$;

-- Ontvangen en verwerken in één aanroep (gebruikt door de webhook-functie)
create or replace function ingest_event(p_trigger_type text, p_payload jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare new_id bigint; key text;
begin
  key := encode(digest(p_payload::text, 'sha256'), 'hex');
  insert into huddle_events (trigger_type, payload, dedupe_key)
  values (coalesce(p_trigger_type, p_payload ->> 'trigger_type', 'onbekend'), p_payload, key)
  on conflict (dedupe_key) do nothing
  returning id into new_id;
  if new_id is not null then
    perform process_event(new_id);
  end if;
  return new_id;
end $$;

-- Alles opnieuw verwerken (bijv. na een aanpassing in process_event)
create or replace function reprocess_all() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  delete from activity; delete from quiz_attempts; delete from certificates;
  delete from module_progress; delete from course_progress;
  delete from memberships where since >= (select coalesce(min(received_at), now()) from huddle_events)
    and member_id in (select huddle_id from members);
  for r in select id from huddle_events order by received_at, id loop
    perform process_event(r.id); n := n + 1;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- Startpositie: leden uit een CSV-export van één toegangsniveau
-- rows = [{"email": "...", "firstname": "...", "lastname": "...", "id": "..."}]
-- ---------------------------------------------------------------------------
create or replace function import_members(p_group_id text, p_group_name text, rows jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare r jsonb; m_id text; n int := 0; mail text;
begin
  if p_group_id is not null then
    insert into groups (id, name) values (p_group_id, coalesce(p_group_name, p_group_id))
    on conflict (id) do nothing;
  end if;
  for r in select * from jsonb_array_elements(rows) loop
    mail := lower(j_text(r, 'email', 'e-mail', 'emailadres'));
    if mail is null then continue; end if;
    select huddle_id into m_id from members where lower(email) = mail;
    if m_id is null then
      m_id := coalesce(j_text(r, 'id', 'user_id'), 'email:' || mail);
      insert into members (huddle_id, email, first_name, last_name, created_at)
      values (m_id, mail, j_text(r, 'firstname', 'voornaam', 'first_name'),
              j_text(r, 'lastname', 'achternaam', 'last_name'),
              nullif(j_text(r, 'created_at', 'aangemaakt'), '')::timestamptz)
      on conflict (huddle_id) do nothing;
    end if;
    if p_group_id is not null then
      insert into memberships (member_id, group_id, since)
      select m_id, p_group_id, now()
       where not exists (select 1 from memberships where member_id = m_id and group_id = p_group_id and until is null);
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
