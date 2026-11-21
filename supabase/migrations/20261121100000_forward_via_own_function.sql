-- Forward leads to QuoteLeadsHQ through this project's own forward-to-qlhq
-- function, which posts to ql-hq's generic funnel-intake. ql-hq no longer
-- needs this project's URL or service key.
--
-- Deploy supabase/functions/forward-to-qlhq first (Verify JWT off: the
-- intake secret is checked by ql-hq).
--
-- Rollback (back to ql-hq's old esh-intake): run this file again with the
-- url set to 'https://wjadekgptkstfdootuol.supabase.co/functions/v1/esh-intake'.
create or replace function public.send_lead_to_qlhq(lead public.leads)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  secret text;
begin
  select decrypted_secret into secret
  from vault.decrypted_secrets
  where name = 'qlhq_intake_secret'
  limit 1;

  if secret is null then
    raise warning 'qlhq_intake_secret is not in Vault; lead % not sent to ql-hq', lead.id;
    return;
  end if;

  perform net.http_post(
    url     := 'https://axjbalzirbdhfuutmmuw.supabase.co/functions/v1/forward-to-qlhq',
    body    := jsonb_build_object('id', lead.id),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-intake-secret', secret
    ),
    timeout_milliseconds := 60000
  );
end;
$$;
