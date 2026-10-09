// provider-vault: server-side encrypted IPTV credential storage.
// Secrets (set in Supabase Dashboard > Project Settings > Edge Functions > Secrets,
// NEVER in GitHub): PROVIDER_ENCRYPTION_KEY = base64 of 32 random bytes.
// SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY are auto-injected.
import { createClient } from "jsr:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "https://acasso01.github.io",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

async function getKey(): Promise<CryptoKey> {
  const b64 = Deno.env.get("PROVIDER_ENCRYPTION_KEY");
  if (!b64) throw new Error("vault_not_configured");
  const raw = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  if (raw.length !== 32) throw new Error("vault_key_invalid");
  return crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
}
const toB64 = (buf: ArrayBuffer | Uint8Array) =>
  btoa(String.fromCharCode(...new Uint8Array(buf as ArrayBuffer)));
const fromB64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const userClient = createClient(
      Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user }, error: authErr } = await userClient.auth.getUser();
    if (authErr || !user) return json({ error: "unauthorized" }, 401);

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
    const key = await getKey();

    if (req.method === "GET") {
      const { data, error } = await admin.from("iptv_providers")
        .select("server_url, username, password_ciphertext, password_iv")
        .eq("user_id", user.id).maybeSingle();
      if (error) throw error;
      if (!data) return json({ saved: false });
      const plain = await crypto.subtle.decrypt(
        { name: "AES-GCM", iv: fromB64(data.password_iv) }, key, fromB64(data.password_ciphertext),
      );
      return json({ saved: true, server_url: data.server_url, username: data.username,
        password: new TextDecoder().decode(plain) });
    }

    if (req.method === "POST") {
      const { server_url, username, password } = await req.json();
      const url = new URL(String(server_url ?? ""));
      if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) {
        return json({ error: "invalid_server_url" }, 400);
      }
      if (!username || !password) return json({ error: "missing_fields" }, 400);
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const cipher = await crypto.subtle.encrypt(
        { name: "AES-GCM", iv }, key, new TextEncoder().encode(String(password)),
      );
      const { error } = await admin.from("iptv_providers").upsert({
        user_id: user.id, server_url: url.href.replace(/\/+$/, ""),
        username: String(username), password_ciphertext: toB64(cipher),
        password_iv: toB64(iv), updated_at: new Date().toISOString(),
      }, { onConflict: "user_id" });
      if (error) throw error;
      return json({ saved: true });
    }

    if (req.method === "DELETE") {
      const { error } = await admin.from("iptv_providers").delete().eq("user_id", user.id);
      if (error) throw error;
      return json({ deleted: true });
    }

    return json({ error: "method_not_allowed" }, 405);
  } catch (e) {
    const msg = e instanceof Error ? e.message : "error";
    const status = msg === "vault_not_configured" || msg === "vault_key_invalid" ? 503 : 500;
    return json({ error: msg }, status);
  }
});
