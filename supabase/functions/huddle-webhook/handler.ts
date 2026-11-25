// Verwerkt één webhookbericht van The Huddle.
// Los van Deno gehouden zodat het ook met Node getest kan worden.

export type Ingest = (triggerType: string | null, payload: unknown) => Promise<{ id: number | null; error?: string }>;

export function tokenMatches(req: Request, expected: string): boolean {
  if (!expected) return false;
  const header = req.headers.get("x-webhook-token") ?? "";
  const query = new URL(req.url).searchParams.get("token") ?? "";
  const given = header || query;
  if (given.length !== expected.length) return false;
  // vergelijking in constante tijd
  let diff = 0;
  for (let i = 0; i < given.length; i++) diff |= given.charCodeAt(i) ^ expected.charCodeAt(i);
  return diff === 0;
}

export async function handle(req: Request, secret: string, ingest: Ingest): Promise<Response> {
  if (req.method !== "POST") return new Response("Alleen POST", { status: 405 });
  if (!tokenMatches(req, secret)) return new Response("Geen toegang", { status: 401 });

  let payload: unknown;
  try {
    payload = await req.json();
  } catch {
    return new Response("Geen geldige JSON", { status: 400 });
  }
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return new Response("Verwacht een JSON-object", { status: 400 });
  }
  const p = payload as Record<string, unknown>;
  const trigger = typeof p.trigger_type === "string" ? p.trigger_type : null;

  const { id, error } = await ingest(trigger, payload);
  if (error) {
    // 500 zodat het in de logs opvalt; Huddle wacht max. 10 seconden
    console.error("ingest mislukt", error);
    return new Response("Opslaan mislukt", { status: 500 });
  }
  return Response.json({ ok: true, id, duplicate: id === null });
}
