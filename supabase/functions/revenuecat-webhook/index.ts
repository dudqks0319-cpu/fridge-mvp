import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

type RevenueCatEvent = {
  id?: string;
  type?: string;
  app_user_id?: string;
  entitlement_ids?: string[];
  expiration_at_ms?: number | null;
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

  const expectedSecret = Deno.env.get("REVENUECAT_WEBHOOK_SECRET");
  if (expectedSecret) {
    const provided = request.headers.get("x-webhook-secret");
    if (provided != expectedSecret) {
      return json(401, { error: "unauthorized" });
    }
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return json(500, { error: "missing_supabase_env" });
  }

  const payload = await request.json().catch(() => null);
  if (!payload || typeof payload !== "object") {
    return json(400, { error: "invalid_json" });
  }

  const event = (payload as { event?: RevenueCatEvent }).event;
  if (!event) {
    return json(400, { error: "missing_event" });
  }

  const eventId = event.id ?? crypto.randomUUID();
  const userId = event.app_user_id ?? null;
  const entitlementIds = Array.isArray(event.entitlement_ids)
    ? event.entitlement_ids
    : [];
  const expiresAt = typeof event.expiration_at_ms === "number"
    ? new Date(event.expiration_at_ms).toISOString()
    : null;
  const status = entitlementIds.length > 0 ? "active" : "inactive";

  const supabase = createClient(supabaseUrl, serviceRoleKey);

  const eventInsert = await supabase.from("revenuecat_events").upsert({
    event_id: eventId,
    user_id: userId,
    event_type: event.type ?? "unknown",
    payload,
  });
  if (eventInsert.error) {
    return json(500, { error: "failed_to_store_event", detail: eventInsert.error.message });
  }

  if (userId) {
    const subscriptionUpsert = await supabase.from("subscription_state").upsert({
      user_id: userId,
      provider: "revenuecat",
      entitlement_ids: entitlementIds,
      status,
      expires_at: expiresAt,
      raw_payload: payload,
    });
    if (subscriptionUpsert.error) {
      return json(500, { error: "failed_to_upsert_subscription", detail: subscriptionUpsert.error.message });
    }
  }

  return json(200, { ok: true, eventId, userId });
});
