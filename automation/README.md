# التقرير اليومي — أسطول الهاشمية

كل يوم الساعة 8 بالليل (توقيت القاهرة) البوت بيبعت لمستلمي التقارير والأدمن:

1. رسالة ملخص على تليجرام (المواقع اللي بعتت، التشغيل، الأعطال، الصيانات، السولار، الخلاطة).
2. ملف إكسل فيه التفاصيل في شيتات: التشغيل، الأعطال، الصيانات، صيانات مستحقة، السولار، التانكات، الخلاطة، حالة المعدات.

## الأجزاء

| الجزء | المكان |
|---|---|
| فانكشن `report_daily(date)` في الداتابيز | `supabase/migrations/20261031133203_daily_report.sql` |
| Edge Function `daily-report` (بتعمل ملف الإكسل) | `supabase/functions/daily-report/index.ts` |
| Workflow للـ n8n (بيبعت على تليجرام) | `automation/n8n-daily-report.json` |

`report_daily` مسموح بيها للـ service role بس، فلازم تنادي الـ Edge Function بالمفتاح السري (secret key).

## التركيب في n8n

1. **Workflows → Import from File** واختار `automation/n8n-daily-report.json`.
2. افتح node **Get report** واعمل Credential من نوع **Header Auth**:
   - Name: `apikey`
   - Value: المفتاح السري من Supabase (**Project Settings → API Keys → secret**).
3. افتح **Send summary** و**Send Excel** واختار الـ Telegram credential بتاع البوت.
4. دوس **Execute workflow** مرة للتجربة، وبعدين فعّل الـ workflow.

## تقرير يوم معين

```
GET https://yyoemzphnwpbbuvpqjzx.supabase.co/functions/v1/daily-report?date=2026-10-31
```

## مين بيستلم

أي مستخدم في جدول `users` دوره `مستلم تقارير` أو `أدمن`، وحسابه `active`، وعنده `telegram_id`.
