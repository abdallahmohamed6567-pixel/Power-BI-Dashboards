-- Daily report now flags meter readings that need review (see meter_reliability).
create or replace function public.report_daily(p_date date default null)
returns jsonb
language plpgsql
stable
set search_path to 'public'
as $function$
declare
  d          date := coalesce(p_date, (now() at time zone 'Africa/Cairo')::date);
  v_sites    int;
  v_sent     int;
  v_missing  text;
  v_worked   int;
  v_idle     int;
  v_hours    numeric;
  v_review   int;
  v_fleet    text;
  v_new_bd   int;
  v_new_list text;
  v_open_bd  int;
  v_mnt      int;
  v_mnt_cost numeric;
  v_late     int;
  v_near     int;
  v_noinfo   int;
  v_fuel_in  numeric;
  v_fuel_out numeric;
  v_tons     numeric;
  v_moves    int;
  v_text     text;
begin
  select count(*) into v_sites from sites where state = 'مفتوح';
  select count(distinct site_id) into v_sent
  from daily_reports where report_date = d and submitted_at is not null;
  select string_agg(s.name, '، ' order by s.name) into v_missing
  from sites s
  where s.state = 'مفتوح'
    and not exists (select 1 from daily_reports r
                    where r.site_id = s.id and r.report_date = d and r.submitted_at is not null);

  select count(*) filter (where de.worked), count(*) filter (where not de.worked), coalesce(sum(de.hours_worked), 0)
  into v_worked, v_idle, v_hours
  from daily_entries de join daily_reports dr on dr.id = de.report_id
  where dr.report_date = d;

  select count(*) into v_review from v_meter_log where report_date = d and review_note is not null;

  select string_agg(status || ' ' || n, ' • ' order by array_position(array['يعمل','قيد الصيانة','خارج الخدمة'], status))
  into v_fleet
  from (select status, count(*) n from equipment group by status) x;

  select count(*), string_agg('  • ' || bot_equipment_label(equipment_code) || ' — ' || coalesce(severity, 'غير محدد'), E'\n')
  into v_new_bd, v_new_list
  from (select * from breakdowns
        where (reported_at at time zone 'Africa/Cairo')::date = d
        order by reported_at limit 5) b;
  select count(*) into v_new_bd from breakdowns where (reported_at at time zone 'Africa/Cairo')::date = d;
  select count(*) into v_open_bd from breakdowns where state = 'مفتوح';

  select count(*), coalesce(sum(cost_egp), 0) into v_mnt, v_mnt_cost
  from maintenance_events where done_at = d;

  select count(*) filter (where state = 'متأخرة'),
         count(*) filter (where state = 'قريبة'),
         count(distinct code) filter (where state = 'مفيش صيانة متسجلة')
  into v_late, v_near, v_noinfo
  from v_maintenance_due;

  select coalesce(sum(litres) filter (where kind = 'وارد'), 0),
         coalesce(sum(litres) filter (where kind <> 'وارد'), 0)
  into v_fuel_in, v_fuel_out
  from fuel_transactions where (at at time zone 'Africa/Cairo')::date = d;

  select coalesce(sum(tons), 0) into v_tons from plant_production where prod_date = d;
  select count(*) into v_moves from transfers where (at at time zone 'Africa/Cairo')::date = d;

  v_text := concat_ws(E'\n',
    '📊 تقرير يوم ' || to_char(d, 'DD/MM/YYYY'),
    '',
    '🏗 المواقع: ' || v_sent || ' من ' || v_sites || ' بعتوا التقرير',
    case when v_missing is not null then '⚠️ مابعتوش: ' || v_missing end,
    '🚜 التشغيل: ' || v_worked || ' اشتغلت • ' || v_idle || ' واقفة • ' || trim_scale(round(v_hours, 1)) || ' ساعة',
    case when v_review > 0 then '🔎 قرايات عداد محتاجة مراجعة: ' || v_review end,
    '🔧 الأسطول: ' || coalesce(v_fleet, '-'),
    '🚨 أعطال جديدة: ' || v_new_bd || ' • مفتوحة: ' || v_open_bd,
    v_new_list,
    '🛠 صيانات اتعملت: ' || v_mnt || case when v_mnt_cost > 0 then ' (' || trim_scale(round(v_mnt_cost)) || ' ج)' else '' end,
    '⏰ صيانات متأخرة: ' || v_late || ' • قريبة: ' || v_near,
    case when v_noinfo > 0 then '❔ معدات ملهاش صيانة متسجلة لسه: ' || v_noinfo end,
    '⛽ سولار: وارد ' || trim_scale(round(v_fuel_in)) || ' لتر • منصرف ' || trim_scale(round(v_fuel_out)) || ' لتر',
    case when v_tons > 0 then '🏭 الخلاطة: ' || trim_scale(round(v_tons, 1)) || ' طن' end,
    case when v_moves > 0 then '🚚 نقل معدات: ' || v_moves end,
    '',
    '📎 التفاصيل في ملف الإكسل');

  return jsonb_build_object(
    'date', d,
    'file_name', 'تقرير-' || to_char(d, 'YYYY-MM-DD') || '.xlsx',
    'text', bot_html(v_text),
    'recipients', (select coalesce(jsonb_agg(telegram_id), '[]'::jsonb) from users
                   where role in ('مستلم تقارير', 'أدمن') and active and telegram_id is not null),
    'sheets', jsonb_build_object(
      'التشغيل', (select coalesce(jsonb_agg(jsonb_build_object(
          'الموقع', s.name, 'الكود', de.equipment_code, 'المعدة', bot_equipment_label(de.equipment_code),
          'اشتغلت', case when de.worked then 'نعم' else 'لا' end, 'سبب الوقوف', de.idle_reason,
          'قراية العداد', de.meter_reading, 'ساعات التشغيل', de.hours_worked, 'مصدر الساعات', de.hours_source,
          'مراجعة العداد', coalesce(ml.review_note, case when ml.is_baseline then 'قراية بداية' end),
          'المشغل', u.name, 'نوع الشغل', de.work_condition, 'ملاحظات', de.notes) order by s.name, de.equipment_code), '[]'::jsonb)
        from daily_entries de join daily_reports dr on dr.id = de.report_id
        join sites s on s.id = dr.site_id left join users u on u.id = de.operator_id
        left join v_meter_log ml on ml.entry_id = de.id
        where dr.report_date = d),
      'الأعطال', (select coalesce(jsonb_agg(jsonb_build_object(
          'التاريخ', to_char(b.reported_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI'), 'الكود', b.equipment_code,
          'المعدة', bot_equipment_label(b.equipment_code), 'الوصف', b.description, 'الخطورة', b.severity,
          'الحالة', b.state, 'بلّغ', u.name) order by b.reported_at), '[]'::jsonb)
        from breakdowns b left join users u on u.id = b.reported_by
        where b.state = 'مفتوح' or (b.reported_at at time zone 'Africa/Cairo')::date = d),
      'الصيانات', (select coalesce(jsonb_agg(jsonb_build_object(
          'الكود', m.equipment_code, 'المعدة', bot_equipment_label(m.equipment_code), 'البند', m.item,
          'العداد', m.meter, 'نوع الزيت', m.oil_grade, 'لترات', m.litres, 'قطع الغيار', m.parts,
          'التكلفة', m.cost_egp, 'أيام التوقف', m.downtime_days, 'بواسطة', u.name, 'ملاحظات', m.notes) order by m.id), '[]'::jsonb)
        from maintenance_events m left join users u on u.id = m.by_user_id
        where m.done_at = d),
      'صيانات مستحقة', (select coalesce(jsonb_agg(jsonb_build_object(
          'الكود', v.code, 'المعدة', bot_equipment_label(v.code), 'البند', v.item, 'الحالة', v.state,
          'المتبقي', round(v.remaining, 1), 'الوحدة', case when v.basis = 'نوع الزيت' then 'ساعة' else v.basis end,
          'آخر مرة', v.last_done) order by v.state desc, v.remaining), '[]'::jsonb)
        from v_maintenance_due v where v.state in ('متأخرة', 'قريبة')),
      'السولار', (select coalesce(jsonb_agg(jsonb_build_object(
          'الوقت', to_char(f.at at time zone 'Africa/Cairo', 'HH24:MI'), 'النوع', f.kind, 'التانك', k.name,
          'المعدة', case when f.equipment_code is not null then bot_equipment_label(f.equipment_code) end,
          'لترات', f.litres, 'التكلفة', f.cost_egp, 'المورد', f.supplier, 'بواسطة', u.name) order by f.at), '[]'::jsonb)
        from fuel_transactions f left join fuel_tanks k on k.id = f.tank_id left join users u on u.id = f.by_user_id
        where (f.at at time zone 'Africa/Cairo')::date = d),
      'التانكات', (select coalesce(jsonb_agg(jsonb_build_object(
          'التانك', t.name, 'الرصيد الدفتري', t.book_litres, 'آخر قياس', t.last_dip_litres, 'تاريخ القياس', t.last_dip_date,
          'الفرق', t.last_dip_litres - t.book_litres) order by t.id), '[]'::jsonb)
        from v_tank_balance t),
      'الخلاطة', (select coalesce(jsonb_agg(jsonb_build_object(
          'الخلاطة', bot_equipment_label(p.plant_code), 'الإنتاج (طن)', p.tons, 'ساعات', p.hours, 'بواسطة', u.name) order by p.id), '[]'::jsonb)
        from plant_production p left join users u on u.id = p.by_user_id
        where p.prod_date = d),
      'حالة المعدات', (select coalesce(jsonb_agg(jsonb_build_object(
          'الموقع', v.site, 'الكود', v.code, 'النوع', v.type, 'الموديل', v.model, 'السنة', v.year,
          'الحالة', v.status, 'آخر عداد', v.last_meter) order by v.site, v.code), '[]'::jsonb)
        from v_site_equipment v)
    ));
end
$function$;

revoke execute on function public.report_daily(date) from public, anon, authenticated;
grant execute on function public.report_daily(date) to service_role;
