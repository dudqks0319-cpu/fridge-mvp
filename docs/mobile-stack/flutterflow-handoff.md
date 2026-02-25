# FlutterFlow + Supabase Handoff

Use this checklist when building screens in FlutterFlow while keeping Supabase as backend.

## Data source rules

1. Auth: Supabase Auth only.
2. User primary key: `auth.users.id` UUID only.
3. App state sync table: `public.fridge_app_state`.
4. Push subscriptions: `public.notification_devices`.
5. Subscription state: `public.subscription_state`.

## FlutterFlow setup

1. Connect Supabase project URL and anon key.
2. Import tables and verify field types.
3. For writes, enforce authenticated users only.
4. Keep business logic in Supabase functions when possible.

## Security checklist

1. RLS enabled for all user tables.
2. No service role key in client app.
3. OAuth callback URLs match Supabase settings.
