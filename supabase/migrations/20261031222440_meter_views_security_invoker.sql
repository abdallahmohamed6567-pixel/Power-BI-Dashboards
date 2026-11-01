-- Views must respect RLS (no policies = only the service key reads data).
alter view public.v_meter_log set (security_invoker = true);
alter view public.v_last_meter set (security_invoker = true);
alter view public.v_maintenance_due set (security_invoker = true);
