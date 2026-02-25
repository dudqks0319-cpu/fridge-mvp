#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

supabase functions deploy revenuecat-webhook
supabase functions deploy onesignal-device-sync

echo "Supabase functions deployed."
