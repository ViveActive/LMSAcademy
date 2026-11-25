#!/usr/bin/env node
// Leest een ledenexport uit The Huddle (CSV) in als startpositie voor één groep.
//
// Gebruik:
//   SUPABASE_URL=https://xxx.supabase.co SUPABASE_SERVICE_ROLE_KEY=... \
//   node scripts/import-csv.mjs export.csv "lvl-id" "Mastertrainers 2026"
//
// Zonder groep (alleen leden):  node scripts/import-csv.mjs export.csv
// Droogtest zonder te versturen: voeg --droog toe.
import { readFileSync } from "node:fs";

export function parseCsv(text) {
  text = text.replace(/^﻿/, "");
  const firstLine = text.split(/\r?\n/, 1)[0];
  const sep = (firstLine.match(/;/g) || []).length >= (firstLine.match(/,/g) || []).length ? ";" : ",";
  const rows = [];
  let row = [], field = "", inQuotes = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (inQuotes) {
      if (ch === '"' && text[i + 1] === '"') { field += '"'; i++; }
      else if (ch === '"') inQuotes = false;
      else field += ch;
    } else if (ch === '"') inQuotes = true;
    else if (ch === sep) { row.push(field); field = ""; }
    else if (ch === "\n" || ch === "\r") {
      if (ch === "\r" && text[i + 1] === "\n") i++;
      row.push(field); field = "";
      if (row.some((f) => f.trim() !== "")) rows.push(row);
      row = [];
    } else field += ch;
  }
  row.push(field);
  if (row.some((f) => f.trim() !== "")) rows.push(row);
  if (rows.length === 0) return [];

  const norm = (h) => h.trim().toLowerCase().replace(/[\s_-]+/g, "");
  const aliases = {
    email: ["email", "emailadres", "emailaddress", "e-mail"],
    firstname: ["firstname", "voornaam"],
    lastname: ["lastname", "achternaam"],
    id: ["id", "userid", "gebruikerid"],
    created_at: ["createdat", "aangemaakt", "aangemaaktop", "registratiedatum"],
  };
  const header = rows[0].map(norm);
  const idx = {};
  for (const [key, names] of Object.entries(aliases)) {
    const i = header.findIndex((h) => names.map(norm).includes(h));
    if (i >= 0) idx[key] = i;
  }
  if (idx.email === undefined) throw new Error(`Geen e-mailkolom gevonden. Kolommen: ${rows[0].join(", ")}`);
  return rows.slice(1).map((r) => {
    const o = {};
    for (const [key, i] of Object.entries(idx)) {
      const v = (r[i] ?? "").trim();
      if (v && v !== "-") o[key] = v;
    }
    return o;
  }).filter((o) => o.email);
}

async function main() {
  const args = process.argv.slice(2).filter((a) => a !== "--droog");
  const droog = process.argv.includes("--droog");
  const [file, groupId = null, groupName = null] = args;
  if (!file) {
    console.error("Gebruik: node scripts/import-csv.mjs <export.csv> [groep-id] [groepsnaam] [--droog]");
    process.exit(1);
  }
  const rows = parseCsv(readFileSync(file, "utf8"));
  console.log(`${rows.length} leden gevonden in ${file}${groupId ? ` voor groep ${groupName ?? groupId}` : ""}`);
  if (droog) { console.log(rows.slice(0, 5)); return; }

  const url = process.env.SUPABASE_URL, key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) throw new Error("Zet SUPABASE_URL en SUPABASE_SERVICE_ROLE_KEY");
  const res = await fetch(`${url}/rest/v1/rpc/import_members`, {
    method: "POST",
    headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ p_group_id: groupId, p_group_name: groupName, rows }),
  });
  if (!res.ok) throw new Error(`Import mislukt: ${res.status} ${await res.text()}`);
  console.log(`Ingelezen: ${await res.text()} leden`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((e) => { console.error(e.message); process.exit(1); });
}
