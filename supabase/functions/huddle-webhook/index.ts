// Supabase Edge Function: ontvangt webhooks van The Huddle.
// Adres: https://<project>.supabase.co/functions/v1/huddle-webhook
// In Huddle als header meegeven: x-webhook-token: <HUDDLE_WEBHOOK_TOKEN>
import { createClient } from "jsr:@supabase/supabase-js@2";
import { handle } from "./handler.ts";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);
const secret = Deno.env.get("HUDDLE_WEBHOOK_TOKEN") ?? "";

Deno.serve((req) =>
  handle(req, secret, async (trigger, payload) => {
    const { data, error } = await supabase.rpc("ingest_event", {
      p_trigger_type: trigger,
      p_payload: payload,
    });
    return { id: (data as number | null) ?? null, error: error?.message };
  })
);
