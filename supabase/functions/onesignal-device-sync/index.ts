import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

type DevicePayload = {
  platform?: "ios" | "android" | "web";
  onesignalSubscriptionId?: string;
  pushToken?: string;
};

function json(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return json(405, { error: "method_not_allowed" });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return json(500, { error: "missing_supabase_env" });
  }

  const authHeader = request.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return json(401, { error: "missing_auth_token" });
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const {
    data: { user },
    error: userError,
  } = await userClient.auth.getUser();

  if (userError || !user) {
    return json(401, { error: "invalid_user_token" });
  }

  const body = (await request.json().catch(() => null)) as DevicePayload | null;
  if (!body) {
    return json(400, { error: "invalid_json" });
  }

  const platform = body.platform;
  const onesignalSubscriptionId = body.onesignalSubscriptionId;
  if (!platform || !onesignalSubscriptionId) {
    return json(400, {
      error: "missing_fields",
      required: ["platform", "onesignalSubscriptionId"],
    });
  }

  const serviceClient = createClient(supabaseUrl, serviceRoleKey);
  const upsert = await serviceClient
    .from("notification_devices")
    .upsert(
      {
        user_id: user.id,
        platform,
        onesignal_subscription_id: onesignalSubscriptionId,
        push_token: body.pushToken ?? null,
        is_active: true,
        last_seen_at: new Date().toISOString(),
      },
      { onConflict: "user_id,platform,onesignal_subscription_id" },
    )
    .select("id")
    .single();

  if (upsert.error) {
    return json(500, { error: "upsert_failed", detail: upsert.error.message });
  }

  return json(200, { ok: true, deviceId: upsert.data.id });
});
