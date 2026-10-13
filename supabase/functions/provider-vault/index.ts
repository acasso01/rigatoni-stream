// provider-vault: server-side encrypted IPTV credential storage.
// Secrets (set in Supabase Dashboard > Project Settings > Edge Functions > Secrets,
// NEVER in GitHub): PROVIDER_ENCRYPTION_KEY = base64 of 32 random bytes.
// SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY are auto-injected.
//
// Multi-provider contract (2026-10-13, backward compatible with single-provider clients):
//   GET            -> { providers: [{ id, label, server_url, username, updated_at }] } (no passwords)
//   GET ?id=<uuid> -> { saved: true, id, label, server_url, username, password }
//                    or { saved: false } when the row is missing / not owned
//   POST { id?, label?, server_url, username, password } -> { saved: true, id }
//                    (id present = update that owned row; absent = insert new row)
//   DELETE         -> { deleted: true } (legacy: deletes all rows for the user)
//   DELETE ?id=<uuid> -> { deleted: true } (ownership-checked single delete)
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
const UUID_RE = /^[0-9a-fA-F-]{36}$/;

function cleanLabel(value: unknown): string {
  const label = String(value ?? "My provider").trim().slice(0, 60);
  return label || "My provider";
}

function cleanServerUrl(value: unknown): string {
  const url = new URL(String(value ?? ""));
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) {
    throw new Error("invalid_server_url");
  }
  return url.href.replace(/\/+$/, "");
}

async function decryptPassword(key: CryptoKey, row: { password_ciphertext: string; password_iv: string }) {
  const plain = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: fromB64(row.password_iv) }, key, fromB64(row.password_ciphertext),
  );
  return new TextDecoder().decode(plain);
}

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
    const params = new URL(req.url).searchParams;
    const idParam = params.get("id");
    if (idParam !== null && !UUID_RE.test(idParam)) {
      return json({ error: "invalid_provider_id" }, 400);
    }

    if (req.method === "GET") {
      if (idParam) {
        const { data, error } = await admin.from("iptv_providers")
          .select("id, label, server_url, username, password_ciphertext, password_iv")
          .eq("user_id", user.id).eq("id", idParam).maybeSingle();
        if (error) throw error;
        if (!data) return json({ saved: false });
        return json({ saved: true, id: data.id, label: data.label,
          server_url: data.server_url, username: data.username,
          password: await decryptPassword(key, data) });
      }
      const { data, error } = await admin.from("iptv_providers")
        .select("id, label, server_url, username, password_ciphertext, password_iv, updated_at")
        .eq("user_id", user.id).order("updated_at", { ascending: false });
      if (error) throw error;
      const providers = (data ?? []).map(
        ({ password_ciphertext, password_iv, ...rest }) => rest);
      if (data && data.length === 1) {
        // Legacy single-provider shape: the old Pi gateway does a bare GET and
        // expects {saved, server_url, username, password}. Include it alongside
        // the list so single-provider users keep working without a Pi rebuild.
        const row = data[0];
        const plain = await crypto.subtle.decrypt(
          { name: "AES-GCM", iv: fromB64(row.password_iv) }, key,
          fromB64(row.password_ciphertext),
        );
        return json({ saved: true, id: row.id, label: row.label,
          server_url: row.server_url, username: row.username,
          password: new TextDecoder().decode(plain), providers });
      }
      return json({ providers });
    }

    if (req.method === "POST") {
      const { id, label, server_url, username, password } = await req.json();
      let serverUrl: string;
      try {
        serverUrl = cleanServerUrl(server_url);
      } catch {
        return json({ error: "invalid_server_url" }, 400);
      }
      if (!username || !password) return json({ error: "missing_fields" }, 400);
      if (id !== undefined && id !== null && !UUID_RE.test(String(id))) {
        return json({ error: "invalid_provider_id" }, 400);
      }
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const cipher = await crypto.subtle.encrypt(
        { name: "AES-GCM", iv }, key, new TextEncoder().encode(String(password)),
      );
      const row = {
        label: cleanLabel(label), server_url: serverUrl, username: String(username),
        password_ciphertext: toB64(cipher), password_iv: toB64(iv),
        updated_at: new Date().toISOString(),
      };
      if (id) {
        const { data, error } = await admin.from("iptv_providers")
          .update(row).eq("id", String(id)).eq("user_id", user.id).select("id");
        if (error) throw error;
        if (!data || data.length === 0) return json({ error: "provider_not_found" }, 404);
        return json({ saved: true, id: data[0].id });
      }
      const { data, error } = await admin.from("iptv_providers")
        .insert({ user_id: user.id, ...row }).select("id").single();
      if (error) throw error;
      return json({ saved: true, id: data.id });
    }

    if (req.method === "DELETE") {
      if (idParam) {
        const { error } = await admin.from("iptv_providers")
          .delete().eq("id", idParam).eq("user_id", user.id);
        if (error) throw error;
        return json({ deleted: true });
      }
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
