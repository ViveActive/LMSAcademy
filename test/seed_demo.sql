-- Verzonnen voorbeelddata voor de demo-modus van het dashboard. Geen echte personen.
-- Stuurt nep-webhooks door ingest_event, zodat dezelfde verwerking als in productie wordt gebruikt.
\set ON_ERROR_STOP on
select setseed(0.42);

insert into groups (id, name, kind, coach) values
  ('lvl-mt26', 'Mastertrainers 2026', 'Mastertrainers', 'Academy-team'),
  ('lvl-noord', 'Clubtrainers Noord', 'Clubtrainers', 'Sanne Mulder'),
  ('lvl-midden', 'Clubtrainers Midden', 'Clubtrainers', 'Joost Bakker'),
  ('lvl-zuid', 'Clubtrainers Zuid', 'Clubtrainers', 'Fatima El Idrissi')
on conflict do nothing;

create temp table demo_mod as
select * from (values
  ('dc1', 1, 'dm1', 'Basis didactiek', true),
  ('dc1', 2, 'dm2', 'Trainingsopbouw en periodisering', true),
  ('dc1', 3, 'dm3', 'Coachen van jeugd', true),
  ('dc1', 4, 'dm4', 'Blessurepreventie', true),
  ('dc1', 5, 'dm5', 'Praktijkopdracht en video-assessment', true),
  ('dc1', 6, 'dm6', 'Clubcultuur en communicatie', false),
  ('dc2', 1, 'dk1', 'Veilig en verantwoord trainen', true),
  ('dc2', 2, 'dk2', 'Oefenstof en organisatie', true),
  ('dc2', 3, 'dk3', 'Spelers begeleiden', true)
) v(course, pos, id, name, req);

insert into courses (id, name, certificate_name, cert_geldig_maanden, position, description) values
  ('dc1', 'Mastertrainer opleiding', 'Mastertrainer', 24, 1, 'Opleiding tot mastertrainer, afgesloten met praktijkopdracht'),
  ('dc2', 'Clubtrainer basis', 'Clubtrainer', 36, 2, 'Basisopleiding voor clubtrainers')
on conflict do nothing;

create temp table demo_people as
with fn as (select array['Anouk','Bas','Carmen','Daan','Eline','Floris','Gijs','Hanna','Ilse','Jesse','Kim','Lars','Merel','Niels','Olga','Pim','Quinten','Roos','Stijn','Tess','Umut','Vera','Wout','Yara','Zeger','Lotte','Milan','Noor','Ruben','Sophie'] a),
     ln as (select array['de Vries','Jansen','Visser','Smit','Meijer','de Boer','Mulder','de Groot','Bos','Vos','Peters','Hendriks','van Dijk','Kok','Dekker'] a)
select i,
       'demo' || i as uid,
       (select a[1 + ((i - 1) % 30)] from fn) as firstname,
       (select a[1 + (((i - 1) * 7 + (i - 1) / 30) % 15)] from ln) as lastname,
       case when i <= 12 then 'lvl-mt26' when i <= 28 then 'lvl-noord' when i <= 44 then 'lvl-midden' else 'lvl-zuid' end as grp,
       -- profiel: hoe ver en hoe recent iemand is
       random() as tempo, random() as recentheid
from generate_series(1, 58) i;

-- Startpositie zoals uit een CSV-export
select import_members(g, null, jsonb_agg(jsonb_build_object('email', uid || '@voorbeeld.nl', 'firstname', firstname, 'lastname', lastname)))
from (select grp as g, uid, firstname, lastname from demo_people) x group by g;

do $$
declare p record; m record; t timestamptz; stop_at timestamptz; done int; nreq int; u jsonb; crs text; cname text; courses text[];
begin
  for p in select * from demo_people loop
    u := jsonb_build_object('id', p.uid, 'firstname', p.firstname, 'lastname', p.lastname,
                            'fullname', p.firstname || ' ' || p.lastname, 'email', p.uid || '@voorbeeld.nl');
    -- 6% nooit ingelogd
    if p.tempo < 0.06 then continue; end if;
    t := now() - interval '84 days' + (p.tempo * 10)::int * interval '1 day';
    stop_at := now() - (case when p.recentheid > 0.45 then p.recentheid * 6
                             when p.recentheid > 0.25 then 20 + p.recentheid * 20
                             else 45 + p.recentheid * 120 end) * interval '1 day';
    perform ingest_event('user_onboarded', jsonb_build_object('trigger_type','user_onboarded','timestamp', t, 'user', u));
    -- clubtrainers doen eerst de basisopleiding, snelle clubtrainers stromen door naar mastertrainer
    courses := case when p.grp = 'lvl-mt26' then array['dc1'] else array['dc2', 'dc1'] end;
    foreach crs in array courses loop
      exit when t > stop_at;
      cname := (select name from courses where id = crs);
      nreq := (select count(*) from demo_mod where course = crs and req);
      perform ingest_event('course_started', jsonb_build_object('trigger_type','course_started','timestamp', t, 'user', u,
              'course', jsonb_build_object('id', crs, 'name', cname)));
      done := 0;
      for m in select * from demo_mod where course = crs order by pos loop
        exit when t > stop_at;
        perform ingest_event('module_started', jsonb_build_object('trigger_type','module_started','timestamp', t, 'user', u,
                'course', jsonb_build_object('id', crs, 'name', cname),
                'module', jsonb_build_object('id', m.id, 'name', m.name, 'position', m.pos)));
        t := t + ((4 + random() * 14) / (0.4 + p.tempo) * case when crs = 'dc2' then 2.2 else 0.9 end) * interval '1 day';
        exit when t > stop_at;
        if m.id = 'dm5' and random() < 0.3 then
          perform ingest_event('quiz_failed', jsonb_build_object('trigger_type','quiz_failed','timestamp', t, 'user', u,
                  'course', jsonb_build_object('id', crs, 'name', cname),
                  'quiz', jsonb_build_object('id','dq5','name','Beoordeling praktijkopdracht')));
          t := t + interval '6 days';
          exit when t > stop_at;
        end if;
        if m.pos in (1, 3, 5) then
          perform ingest_event('quiz_passed', jsonb_build_object('trigger_type','quiz_passed','timestamp', t, 'user', u,
                  'course', jsonb_build_object('id', crs, 'name', cname),
                  'quiz', jsonb_build_object('id','dq' || m.id, 'name', 'Toets ' || m.name)));
        end if;
        perform ingest_event('module_completed', jsonb_build_object('trigger_type','module_completed','timestamp', t, 'user', u,
                'course', jsonb_build_object('id', crs, 'name', cname),
                'module', jsonb_build_object('id', m.id, 'name', m.name, 'position', m.pos)));
        if m.req then done := done + 1; end if;
        if m.req and done = nreq then
          perform ingest_event('course_completed', jsonb_build_object('trigger_type','course_completed','timestamp', t, 'user', u,
                  'course', jsonb_build_object('id', crs, 'name', cname)));
          perform ingest_event('certificate_sent', jsonb_build_object('trigger_type','certificate_sent','timestamp', t, 'user', u,
                  'course', jsonb_build_object('id', crs, 'name', cname),
                  'certificate', jsonb_build_object('id','cert-' || crs, 'name', (select certificate_name from courses where id = crs))));
        end if;
        t := t + (1 + random() * 3) * interval '1 day';
      end loop;
      exit when done < nreq or p.tempo < 0.55;  -- alleen snelle clubtrainers gaan door
    end loop;
  end loop;
end $$;

update modules m set required = d.req, position = d.pos, course_id = d.course from demo_mod d where d.id = m.id;
-- Een oud certificaat dat binnenkort verloopt
update certificates set issued_at = now() - interval '22 months'
 where id = (select min(id) from certificates where course_id = 'dc1');
update members set measured_since = now() - interval '84 days';
