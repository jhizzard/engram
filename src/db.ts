/**
 * Mnestra — Supabase client factory
 *
 * Reads credentials from environment variables only. Never hardcode URLs
 * or keys in this file — if your deployment needs them baked in, pass them
 * via a wrapper script, not by editing source.
 */

import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { createRequire } from 'node:module';

let cached: SupabaseClient | null = null;

// Node 18/20 LTS don't ship native WebSocket. @supabase/realtime-js's
// RealtimeClient throws "Node.js 20 detected without native WebSocket support"
// at constructor time when no transport is supplied — every memory_* MCP call
// fails before any network I/O. Brad reported this from his R730 (Node 20.20.2)
// on 2026-05-08; ws was not installed and the entire MCP surface was dead.
//
// On Node <22 we lazy-load 'ws' (declared as optionalDependency so installs
// succeed on Node ≥22 without it) and pass it through realtime.transport.
// On Node ≥22 globalThis.WebSocket exists and we leave realtime unconfigured.
function getWsTransport(): unknown | undefined {
  if (typeof (globalThis as { WebSocket?: unknown }).WebSocket !== 'undefined') {
    return undefined;
  }
  try {
    const req = createRequire(import.meta.url);
    return req('ws');
  } catch {
    console.warn(
      '[mnestra] Node <22 detected without native WebSocket and the optional "ws" package is not installed. ' +
        'Realtime transport may fail. Install with: npm install -g ws'
    );
    return undefined;
  }
}

export function getSupabase(): SupabaseClient {
  if (cached) return cached;

  const url = process.env.SUPABASE_URL ?? '';
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY ?? '';

  if (!url || !key) {
    console.error(
      '[mnestra] missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY — set them in your MCP client env'
    );
    throw new Error('Mnestra: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required');
  }

  const wsTransport = getWsTransport();

  cached = createClient(url, key, {
    auth: { autoRefreshToken: false, persistSession: false },
    ...(wsTransport
      ? { realtime: { transport: wsTransport as never } }
      : {}),
  });

  return cached;
}

/**
 * Reset the cached client. Intended for tests only.
 */
export function resetSupabaseClient(): void {
  cached = null;
}
