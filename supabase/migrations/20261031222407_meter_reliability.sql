-- Meter readings: editable with an audit trail, suspicious readings flagged instead of rejected,
-- first reading is a baseline, broken meters use estimated hours, replaced meters keep counting.

create table public.meter_changes (
  id            serial primary key,
  equipment_code text not null references public.equipment(code),
  changed_on    date not null default current_date,
  old_reading   numeric not null,
  new_reading   numeric not null,
  by_user_id    int references public.users(id),
  note          text
);
alter table public.meter_changes enable row level security;

create table public.meter_corrections (
  id            serial primary key,
  entry_id      int not null references public.daily_entries(id) on delete cascade,
  equipment_code text not null,
  old_reading   numeric,
  new_reading   numeric,
  by_user_id    int references public.users(id),
  at            timestamptz not null default now(),
  reason        text
);
alter table public.meter_corrections enable row level security;

-- Readings after a meter replacement are shifted so the count continues from the old meter.
create or replace function public.meter_offset(p_code text, p_date date)
returns numeric
language sql
stable
set search_path to 'public'
as $function$
  select coalesce(sum(old_reading - new_reading), 0)
  from meter_changes where equipment_code = p_code and changed_on <= p_date
$function$;

create or replace function public.log_meter_correction()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
begin
  if new.meter_reading is distinct from old.meter_reading then
    insert into meter_corrections(entry_id, equipment_code, old_reading, new_reading, by_user_id, reason)
    values (new.id, new.equipment_code, old.meter_reading, new.meter_reading,
            nullif(current_setting('app.user_id', true), '')::int,
            nullif(current_setting('app.reason', true), ''));
  end if;
  return new;
end
$function$;

create trigger daily_entries_meter_audit
after update of meter_reading on public.daily_entries
for each row execute function public.log_meter_correction();

-- Every reading with the one before it, computed on the fly so a correction re-checks its neighbours.
create view public.v_meter_log as
with r as (
  select de.id as entry_id, de.equipment_code, dr.report_date, t.meter_unit as unit,
         de.meter_reading as raw, de.meter_reading + meter_offset(de.equipment_code, dr.report_date) as eff,
         nullif(e.start_meter, 0) as start_meter
  from daily_entries de
  join daily_reports dr on dr.id = de.report_id
  join equipment e on e.code = de.equipment_code
  join equipment_types t on t.id = e.type_id
  where de.meter_reading is not null and t.meter_unit <> 'مفيش'
), l as (
  select r.*,
         coalesce(lag(eff) over w, start_meter) as prev_eff,
         lag(report_date) over w as prev_date,
         greatest(report_date - lag(report_date) over w, 1) as days
  from r
  window w as (partition by equipment_code order by report_date, entry_id)
)
select entry_id, equipment_code, report_date, unit, raw, eff, prev_eff, prev_date,
       prev_eff is null as is_baseline,
       eff - prev_eff as diff,
       case
         when prev_eff is null then null
         when eff < prev_eff then 'أقل من القراية اللي قبلها (' || trim_scale(prev_eff) || ')'
         when prev_date is not null
              and eff - prev_eff > case unit when 'كم' then 1000 else 24 end * days
           then 'زيادة كبيرة: ' || trim_scale(eff - prev_eff) || ' ' || unit || ' في ' || days || ' يوم'
       end as review_note
from l;

-- Latest trusted reading by date (not the max), plus estimated hours logged after it while the meter was broken.
create or replace view public.v_last_meter as
select e.code,
       coalesce(lr.eff, e.start_meter)
       + case when t.meter_unit = 'ساعة' then coalesce((
           select sum(de.hours_worked)
           from daily_entries de join daily_reports dr on dr.id = de.report_id
           where de.equipment_code = e.code and de.meter_reading is null and de.hours_source = 'تقديري'
             and (lr.report_date is null or dr.report_date > lr.report_date)), 0)
         else 0 end as last_meter
from equipment e
join equipment_types t on t.id = e.type_id
left join lateral (
  select m.eff, m.report_date from v_meter_log m
  where m.equipment_code = e.code and m.review_note is null
  order by m.report_date desc, m.entry_id desc limit 1
) lr on true;

-- Same as before, but the meter at service time is shifted by any later meter replacement.
create or replace view public.v_maintenance_due as
with rule as (
  select e.code, e.status, t.name as type, r_1.item, r_1.basis, r_1.every,
         row_number() over (partition by e.code, r_1.item order by (r_1.work_condition = 'الكل')) as rn
  from equipment e
  join equipment_types t on t.id = e.type_id
  join maintenance_rules r_1 on r_1.type_id = e.type_id and (r_1.work_condition = 'الكل' or r_1.work_condition = e.work_condition)
), last_ev as (
  select distinct on (m.equipment_code, m.item) m.equipment_code, m.item, m.done_at,
         m.meter + meter_offset(m.equipment_code, m.done_at) as meter, m.oil_grade
  from maintenance_events m
  order by m.equipment_code, m.item, m.done_at desc, m.id desc
)
select r.code, r.type, r.item, r.basis,
       case when r.basis = 'نوع الزيت' then og.hours else r.every end as every,
       le.done_at as last_done,
       le.meter as last_meter_at_service,
       lm.last_meter,
       case
         when r.basis = 'يوم' and le.done_at is not null then (le.done_at + r.every - current_date)::numeric
         when r.basis = any (array['ساعة', 'كم']) and le.meter is not null then le.meter + r.every::numeric - lm.last_meter
         when r.basis = 'نوع الزيت' and le.meter is not null and og.hours is not null then le.meter + og.hours::numeric - lm.last_meter
         else null::numeric
       end as remaining,
       case
         when r.status = 'خارج الخدمة' then 'خارج الخدمة'
         when le.done_at is null then 'مفيش صيانة متسجلة'
         when r.basis = 'نوع الزيت' and le.oil_grade is null then 'محتاج نوع الزيت'
         when case
                when r.basis = 'يوم' then (le.done_at + r.every - current_date)::numeric
                when r.basis = any (array['ساعة', 'كم']) then le.meter + r.every::numeric - lm.last_meter
                else le.meter + og.hours::numeric - lm.last_meter
              end < 0 then 'متأخرة'
         when case
                when r.basis = 'يوم' then (le.done_at + r.every - current_date)::numeric
                when r.basis = 'ساعة' then (le.meter + r.every::numeric - lm.last_meter) / 25.0
                when r.basis = 'كم' then (le.meter + r.every::numeric - lm.last_meter) / 500.0
                else (le.meter + og.hours::numeric - lm.last_meter) / 25.0
              end <= 1 then 'قريبة'
         else 'سليمة'
       end as state
from rule r
left join last_ev le on le.equipment_code = r.code and le.item = r.item
left join oil_grades og on og.grade = le.oil_grade
left join v_last_meter lm on lm.code = r.code
where r.rn = 1;

-- #9: pin search_path on the remaining bot helpers.
alter function public.bot_distance_m set search_path to 'public';
alter function public.bot_html(text) set search_path to 'public';
alter function public.bot_msg(text, text, jsonb) set search_path to 'public';
