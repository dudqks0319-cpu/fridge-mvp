# Supabase Edge Functions

This folder contains backend automations for the mobile stack.

## Functions

1. `revenuecat-webhook`: receives RevenueCat webhook events and upserts `subscription_state`.
2. `onesignal-device-sync`: stores OneSignal subscription IDs per authenticated user.

## Required Secrets

Set these in Supabase project secrets before deploy:

```bash
SUPABASE_URL
SUPABASE_ANON_KEY
SUPABASE_SERVICE_ROLE_KEY
REVENUECAT_WEBHOOK_SECRET   # optional but recommended
```

## Deploy Commands

```bash
supabase functions deploy revenuecat-webhook
supabase functions deploy onesignal-device-sync
```
