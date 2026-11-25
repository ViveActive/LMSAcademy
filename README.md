# LMSacademy: voortgangsrapportage naast The Huddle

The Huddle blijft het platform voor leden. Deze app vangt de webhooks van Huddle op en toont
prestaties, voortgang en activiteit van leden op drie niveaus: **totaal**, **per groep** en **per lid**.

```
The Huddle ──webhook──▶ Supabase Edge Function ──▶ Postgres (ruwe events → overzichtstabellen → views)
                                                              │
CSV-export leden (eenmalig) ──scripts/import-csv.mjs──────────┘
                                                              ▼
                                               Dashboard (statische site op Vercel)
```

## Wat zit waar

| Pad | Inhoud |
|---|---|
| `supabase/migrations/` | Schema, verwerking van webhooks, rapportageviews, beveiliging (RLS) |
| `supabase/functions/huddle-webhook/` | Ontvanger voor Huddle-webhooks |
| `scripts/import-csv.mjs` | Leest een ledenexport uit Huddle in als startpositie |
| `dashboard/` | Het dashboard (HTML/JS, geen build-stap). Zonder `config.js` draait het met demodata |
| `test/` | Tests en verzonnen demodata |

## Wat "actief" betekent

Huddle meldt via webhooks alleen **leergebeurtenissen**: cursus of module gestart/voltooid, quiz
gehaald/niet gehaald, certificaat verzonden en eerste login. Gewoon inloggen, een les lezen of een
communitybericht wordt niet doorgegeven. "Actief" betekent hier dus: *laatste leergebeurtenis*.
De grenzen (14/30/60 dagen) staan in de tabel `settings` en zijn zonder code aan te passen.

Webhooks melden alleen wat er na het aanzetten gebeurt. Oudere voortgang zit er niet in.

## Installatie

### 1. Supabase

1. Maak een project aan (regio EU, bijv. Frankfurt).
2. Voer de migraties uit: `supabase link --project-ref <ref>` en `supabase db push`
   (of plak de drie bestanden uit `supabase/migrations/` op volgorde in de SQL-editor).
3. Zet het geheim voor de webhook en deploy de functie:
   ```
   supabase secrets set HUDDLE_WEBHOOK_TOKEN=<lange willekeurige tekst>
   supabase functions deploy huddle-webhook --no-verify-jwt
   ```
4. Voeg beheerders toe: `insert into admins (email) values ('jij@voorbeeld.nl');`
5. Zet onder *Authentication > URL Configuration* de Site URL op het Vercel-adres van het dashboard.

### 2. Webhooks in The Huddle

*Instellingen > Automatiseringen*: maak per trigger een regel met actie **Webhook aanroepen**.

- URL: `https://<ref>.supabase.co/functions/v1/huddle-webhook`
- Header: `x-webhook-token: <HUDDLE_WEBHOOK_TOKEN>`
  (kan de header niet, gebruik dan `...huddle-webhook?token=<HUDDLE_WEBHOOK_TOKEN>`)

Triggers om aan te zetten: gebruiker aangemaakt, gebruiker verwijderd, gebruiker logt voor het eerst in,
toegangsniveau toegevoegd / verwijderd / verlopen, cursus gestart / voltooid, module gestart / voltooid,
quiz gehaald / niet gehaald, certificaat verzonden.

Controleer na de eerste berichten in Supabase: `select trigger_type, error, payload from huddle_events order by id desc limit 20;`
De veldnamen van Huddle zijn niet volledig gedocumenteerd. Staat er een `error`, pas dan
`process_event` aan en draai `select reprocess_all();`. Er gaat niets verloren: elk bericht wordt eerst onbewerkt bewaard.

### 3. Startpositie

Exporteer in Huddle per toegangsniveau de leden (*Gebruikers > Beheren > filter > Actie selecteren > Gebruikers exporteren*)
en lees ze in:

```
SUPABASE_URL=https://<ref>.supabase.co SUPABASE_SERVICE_ROLE_KEY=<service key> \
  node scripts/import-csv.mjs export.csv "<groep-id>" "Clubtrainers Noord"
```

Gebruik als groep-id hetzelfde id dat Huddle in de toegangsniveau-webhook meestuurt (zie `groups` na het eerste bericht),
anders ontstaan er twee groepen. Daarna in de tabel `groups` per groep `kind` (Mastertrainers/Clubtrainers) en `coach` invullen,
en niveaus die geen groep zijn op `hidden = true` zetten.

### 4. Dashboard op Vercel

Importeer deze repository in Vercel en zet de omgevingsvariabelen `SUPABASE_URL` en `SUPABASE_ANON_KEY`.
`vercel.json` regelt de rest. Inloggen gaat met een inloglink per e-mail, alleen voor adressen in `admins`
(maak de gebruiker eerst aan onder *Authentication > Users*).

## Lokaal

```
npm test               # webhook-ontvanger en CSV-import
npm run test:db        # database (PGHOST/PGPORT/PGUSER naar een lokale Postgres 16+)
npm run demo           # dashboard met demodata op http://localhost:8000
scripts/build-demo.sh  # demodata opnieuw genereren
```

## Privacy

De database bevat naam, e-mail en leervoortgang van leden. Sluit verwerkersovereenkomsten af met
Supabase en Vercel en vermeld de rapportage in je privacyverklaring.
