// Vercel-build: schrijft dashboard/config.js uit omgevingsvariabelen.
// Zonder variabelen draait het dashboard als demo.
import { writeFileSync } from "node:fs";
const url = process.env.SUPABASE_URL, key = process.env.SUPABASE_ANON_KEY;
if (url && key) {
  writeFileSync("dashboard/config.js", `window.APP_CONFIG = ${JSON.stringify({ supabaseUrl: url, supabaseAnonKey: key })};\n`);
  console.log("config.js geschreven voor", url);
} else {
  console.log("Geen SUPABASE_URL/SUPABASE_ANON_KEY: dashboard draait als demo");
}
