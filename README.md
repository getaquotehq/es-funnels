# Energy Saver Hub funnels

Meta-ads landing page for Energy Saver Hub (operated by The Pirotta Group):
free, no-obligation solar and battery site visit and quote, Victoria only.

| Path | What |
|---|---|
| `index.html` | Landing page + 5-step booking form (Meta Pixel `1008923305193180`) |
| `privacy-policy/` | Privacy Policy |
| `terms/` | Terms & Conditions, including the $500 offer conditions (`#offer`) |
| `logo.png`, `favicon.png`, `apple-touch-icon.png` | Brand assets cut from `ESH Sharper Logo Preview.png` |
| `supabase/migrations/` | Database setup for ESH's Supabase project `axjbalzirbdhfuutmmuw` |

Brand: `#f4943f` orange, `#494D4B` grey, Poppins.

## $500 offer

No end date is shown; the offer runs until it is taken down. To end it,
remove the elements marked `offer-live` in `index.html` (offer bar, the
"$500 off" point under the headline, the $500 section) and update the offer
section of `terms/index.html`. The ads also say "$500 off this month".

## Where leads go

1. The form uploads the optional bill to the private `bills` bucket and inserts
   into `leads` (publishable key: insert only, no read back). Non-Victorian
   postcodes and renters are stopped before submit.
2. The `leads_forward` trigger then, asynchronously:
   - POSTs a flat JSON copy to the Make.com webhook (a fixed list of fields,
     so the Make scenario's mapping never changes when the row does), and
   - POSTs the row to ql-hq's `esh-intake` function (ql-backend), which creates
     the lead under **The Pirotta Group** in QuoteLeadsHQ, copies the bill, and
     writes `qlhq_lead_id` / `qlhq_synced_at` back.
   The consent record (the exact consent line shown, when, and on which page)
   rides in `tracking.consent`; `esh-intake` turns it into the lead's
   `consent_text` in ql-hq, which shows read only on the lead.
3. Leads ql-hq missed can be re-sent with `select public.forward_leads_to_qlhq();`.

Inbox view: Table Editor > Views > `lead_inbox` (Melbourne time).

This is completely separate from TFA Solar (`tfa-funnels`): its own Supabase
project, its own ql-hq function, secret and company.

## One-off setup (ESH Supabase SQL editor)

1. Run `supabase/migrations/20261116000000_leads_bills_and_forwarding.sql`.
2. Store the intake secret (same value as `ESH_INTAKE_SECRET` in ql-hq):
   `select vault.create_secret('<secret>', 'qlhq_intake_secret');`
3. In ql-hq's Edge Function secrets, set `ESH_SERVICE_ROLE_KEY` to this
   project's secret key (needed for bill copy + write-back).
