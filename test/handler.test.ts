// node --experimental-strip-types --test test/handler.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { handle } from "../supabase/functions/huddle-webhook/handler.ts";

const SECRET = "geheim-123";
const calls: unknown[] = [];
const ingest = async (t: string | null, p: unknown) => { calls.push([t, p]); return { id: 7 }; };
const req = (body: string, headers: Record<string, string> = {}, url = "https://x/huddle-webhook", method = "POST") =>
  new Request(url, { method, body: method === "POST" ? body : undefined, headers });

test("weigert zonder token", async () => {
  const r = await handle(req("{}"), SECRET, ingest);
  assert.equal(r.status, 401);
});
test("weigert verkeerd token", async () => {
  const r = await handle(req("{}", { "x-webhook-token": "geheim-124" }), SECRET, ingest);
  assert.equal(r.status, 401);
});
test("weigert GET", async () => {
  const r = await handle(req("", {}, "https://x/", "GET"), SECRET, ingest);
  assert.equal(r.status, 405);
});
test("weigert ongeldige JSON", async () => {
  const r = await handle(req("{kapot", { "x-webhook-token": SECRET }), SECRET, ingest);
  assert.equal(r.status, 400);
});
test("accepteert bericht met header", async () => {
  const body = JSON.stringify({ trigger_type: "module_completed", user: { id: "u1" } });
  const r = await handle(req(body, { "x-webhook-token": SECRET }), SECRET, ingest);
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { ok: true, id: 7, duplicate: false });
  assert.equal((calls.at(-1) as unknown[])[0], "module_completed");
});
test("accepteert token in querystring", async () => {
  const r = await handle(req("{\"trigger_type\":\"x\"}", {}, `https://x/?token=${SECRET}`), SECRET, ingest);
  assert.equal(r.status, 200);
});
test("geeft 500 bij databasefout", async () => {
  const r = await handle(req("{}", { "x-webhook-token": SECRET }), SECRET, async () => ({ id: null, error: "db" }));
  assert.equal(r.status, 500);
});
test("leeg geheim weigert alles", async () => {
  const r = await handle(req("{}", { "x-webhook-token": "" }), "", ingest);
  assert.equal(r.status, 401);
});
