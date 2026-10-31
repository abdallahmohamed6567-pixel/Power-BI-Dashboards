// Daily owner report: returns the Telegram summary, the recipients and an Excel file (base64).
// Call with the project's secret/service key; report_daily() is only executable by service_role.
//   GET /functions/v1/daily-report            -> today (Cairo)
//   GET /functions/v1/daily-report?date=2026-10-31
import * as XLSX from "npm:xlsx@0.18.5";

// jsonb sorts keys, so the column order of each sheet lives here.
const COLUMNS: Record<string, string[]> = {
  "التشغيل": ["الموقع", "الكود", "المعدة", "اشتغلت", "سبب الوقوف", "قراية العداد", "ساعات التشغيل", "مصدر الساعات", "المشغل", "نوع الشغل", "ملاحظات"],
  "الأعطال": ["التاريخ", "الكود", "المعدة", "الوصف", "الخطورة", "الحالة", "بلّغ"],
  "الصيانات": ["الكود", "المعدة", "البند", "العداد", "نوع الزيت", "لترات", "قطع الغيار", "التكلفة", "أيام التوقف", "بواسطة", "ملاحظات"],
  "صيانات مستحقة": ["الكود", "المعدة", "البند", "الحالة", "المتبقي", "الوحدة", "آخر مرة"],
  "السولار": ["الوقت", "النوع", "التانك", "المعدة", "لترات", "التكلفة", "المورد", "بواسطة"],
  "التانكات": ["التانك", "الرصيد الدفتري", "آخر قياس", "تاريخ القياس", "الفرق"],
  "الخلاطة": ["الخلاطة", "الإنتاج (طن)", "ساعات", "بواسطة"],
  "حالة المعدات": ["الموقع", "الكود", "النوع", "الموديل", "السنة", "الحالة", "آخر عداد"],
};

Deno.serve(async (req) => {
  const date = new URL(req.url).searchParams.get("date");
  if (date && !/^\d{4}-\d{2}-\d{2}$/.test(date)) {
    return json({ error: "date must be YYYY-MM-DD" }, 400);
  }

  // Forward the caller's key so the database decides who may read the report.
  // sb_secret_ keys are not JWTs, so only pass Authorization on when it holds one.
  const bearer = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  const apikey = req.headers.get("apikey") || bearer;
  const headers: Record<string, string> = { apikey, "content-type": "application/json" };
  if (bearer.startsWith("eyJ")) headers.authorization = `Bearer ${bearer}`;
  const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/rest/v1/rpc/report_daily`, {
    method: "POST",
    headers,
    body: JSON.stringify({ p_date: date }),
  });
  if (!res.ok) return json({ error: await res.text() }, res.status === 401 || res.status === 403 ? 403 : 502);
  const report = await res.json();

  const wb = XLSX.utils.book_new();
  wb.Workbook = { Views: [{ RTL: true }] };
  for (const [name, columns] of Object.entries(COLUMNS)) {
    const rows: Record<string, unknown>[] = report.sheets[name] ?? [];
    const ws = XLSX.utils.json_to_sheet(rows, { header: columns });
    ws["!cols"] = columns.map((c) => ({
      wch: Math.min(40, Math.max(c.length, ...rows.map((r) => String(r[c] ?? "").length)) + 2),
    }));
    XLSX.utils.book_append_sheet(wb, ws, name);
  }

  return json({
    date: report.date,
    text: report.text,
    recipients: report.recipients,
    file_name: report.file_name,
    file_base64: XLSX.write(wb, { type: "base64", bookType: "xlsx" }),
  });
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
