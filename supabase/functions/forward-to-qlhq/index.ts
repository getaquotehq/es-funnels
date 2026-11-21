// Forward a lead from this funnel's project to QuoteLeadsHQ (ql-hq).
//
// The leads trigger (send_lead_to_qlhq) posts the new row here with the
// qlhq_intake_secret from Vault. We reload the row from our own database (so
// only real rows are ever sent), make a 10-minute signed link to the bill, and
// pass both to ql-hq's funnel-intake with the same secret, which ql-hq checks.
// ql-hq returns its lead id, written back on our row so resends are safe.
//
// Single file, no secrets to set: it uses this project's built-in keys.
// The same file serves every client funnel; keep the copies identical.
import { createClient } from 'npm:@supabase/supabase-js@2'

const QLHQ_INTAKE = 'https://wjadekgptkstfdootuol.supabase.co/functions/v1/funnel-intake'
const BILL_BUCKET = 'bills'

const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { 'Content-Type': 'application/json' } })

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ ok: false }, 405)
  const secret = req.headers.get('x-intake-secret') || ''
  const body = await req.json().catch(() => null) as Record<string, any> | null
  const id = body?.record?.id ?? body?.id
  if (!secret || typeof id !== 'string') return json({ ok: false }, 400)

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const { data: row } = await db.from('leads').select('*').eq('id', id).maybeSingle()
  if (!row) return json({ ok: false }, 404)

  let bill_url: string | null = null
  if (row.bill_path) {
    const { data } = await db.storage.from(BILL_BUCKET).createSignedUrl(row.bill_path, 600)
    bill_url = data?.signedUrl ?? null
  }

  const res = await fetch(QLHQ_INTAKE, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-intake-secret': secret },
    body: JSON.stringify({ record: row, bill_url }),
    signal: AbortSignal.timeout(60_000),
  })
  const out = await res.json().catch(() => ({})) as Record<string, any>
  if (!res.ok || !out.success) return json({ ok: false, status: res.status }, 502)

  if (out.complete) {
    await db.from('leads').update({ qlhq_lead_id: out.lead_id, qlhq_synced_at: new Date().toISOString() }).eq('id', id)
  }
  return json({ ok: true, lead_id: out.lead_id, bill_attached: out.bill_attached })
})
