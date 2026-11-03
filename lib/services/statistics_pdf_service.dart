import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shca/models/health_statistics.dart';

const Map<int, String> statisticsExportPeriods = <int, String>{
  1: 'Today',
  7: 'Last 7 days',
  30: 'Last 30 days',
  90: 'Last 90 days',
};

class StatisticsPdfService {
  const StatisticsPdfService();

  Future<Uint8List> buildReport({
    required String personName,
    required HealthStatistics statistics,
    required bool fromCache,
  }) async {
    final regularFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/Roboto-Regular.ttf'),
    );
    final boldFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/Roboto-Bold.ttf'),
    );
    final document = pw.Document(
      title: 'SHCA health statistics report',
      author: 'Smart Health Care Assistant',
      subject: 'Recorded medication and possible-fall statistics',
      creator: 'SHCA',
    );
    const orange = PdfColor.fromInt(0xFFFF7518);
    const dark = PdfColor.fromInt(0xFF241D19);
    const muted = PdfColor.fromInt(0xFF665C56);
    const pale = PdfColor.fromInt(0xFFFFF3E7);
    const border = PdfColor.fromInt(0xFFF0D7C4);
    final insights = statistics.smartInsights;
    final outlook = statistics.outlook;
    final recordedDays = statistics.days
        .where((day) => day.doses > 0 || day.alerts > 0)
        .toList();
    final recentDays = recordedDays.length <= 7
        ? recordedDays
        : recordedDays.sublist(recordedDays.length - 7);

    document.addPage(
      pw.Page(
        pageTheme: pw.PageTheme(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(30, 28, 30, 24),
          theme: pw.ThemeData.withFont(base: regularFont, bold: boldFont),
        ),
        build: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: <pw.Widget>[
            pw.Container(
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(
                color: pale,
                borderRadius: pw.BorderRadius.circular(10),
                border: pw.Border.all(color: border),
              ),
              child: pw.Row(
                children: [
                  pw.Container(
                    width: 34,
                    height: 34,
                    alignment: pw.Alignment.center,
                    decoration: pw.BoxDecoration(
                      color: orange,
                      borderRadius: pw.BorderRadius.circular(9),
                    ),
                    child: pw.Text(
                      'S',
                      style: pw.TextStyle(
                        color: PdfColors.white,
                        fontSize: 20,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ),
                  pw.SizedBox(width: 11),
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          'Health Statistics Summary',
                          style: pw.TextStyle(
                            color: dark,
                            fontSize: 18,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        pw.Text(
                          '${personName.trim().isEmpty ? 'Linked elderly account' : personName.trim()}  •  ${_date(statistics.start)} – ${_date(statistics.asOf)}',
                          style: const pw.TextStyle(color: muted, fontSize: 9),
                        ),
                      ],
                    ),
                  ),
                  pw.Container(
                    padding: const pw.EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    decoration: pw.BoxDecoration(
                      color: PdfColors.white,
                      borderRadius: pw.BorderRadius.circular(7),
                      border: pw.Border.all(color: border),
                    ),
                    child: pw.Text(
                      '${statistics.days.length}-day view',
                      style: pw.TextStyle(
                        color: dark,
                        fontSize: 8,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (fromCache) ...[
              pw.SizedBox(height: 5),
              pw.Container(
                width: double.infinity,
                padding: const pw.EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                color: PdfColors.amber50,
                child: pw.Text(
                  'Offline copy: these records may be incomplete.',
                  style: const pw.TextStyle(fontSize: 7.5, color: muted),
                ),
              ),
            ],
            pw.SizedBox(height: 10),
            _heading('Overview', dark),
            pw.SizedBox(height: 5),
            pw.Row(
              children: [
                _metric(
                  'Completion',
                  statistics.completion == null
                      ? '—'
                      : '${statistics.completion!.toStringAsFixed(0)}%',
                  orange,
                  border,
                ),
                pw.SizedBox(width: 6),
                _metric('Saved doses', '${statistics.doses}', orange, border),
                pw.SizedBox(width: 6),
                _metric('Alert events', '${statistics.alerts}', orange, border),
                pw.SizedBox(width: 6),
                _metric(
                  'Recorded days',
                  '${statistics.recordDays}/${statistics.days.length}',
                  orange,
                  border,
                ),
              ],
            ),
            pw.SizedBox(height: 9),
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Expanded(
                  child: _breakdown(
                    title: 'Medication outcomes',
                    values: <MapEntry<String, int>>[
                      MapEntry('Taken', statistics.taken),
                      MapEntry('Missed', statistics.missed),
                      MapEntry('Unresolved', statistics.unresolved),
                    ],
                    pale: pale,
                    border: border,
                    dark: dark,
                    muted: muted,
                  ),
                ),
                pw.SizedBox(width: 8),
                pw.Expanded(
                  child: _breakdown(
                    title: 'Possible-fall alert outcomes',
                    values: statistics.fallStatuses.entries.toList(),
                    pale: pale,
                    border: border,
                    dark: dark,
                    muted: muted,
                  ),
                ),
              ],
            ),
            pw.SizedBox(height: 10),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                _heading('Latest recorded days', dark),
                pw.Text(
                  recordedDays.length > 7
                      ? 'Latest 7 shown; overview uses the full period'
                      : 'Overview uses the full selected period',
                  style: const pw.TextStyle(fontSize: 7, color: muted),
                ),
              ],
            ),
            pw.SizedBox(height: 5),
            if (recentDays.isEmpty)
              pw.Container(
                width: double.infinity,
                padding: const pw.EdgeInsets.all(9),
                decoration: pw.BoxDecoration(
                  color: pale,
                  border: pw.Border.all(color: border),
                ),
                child: pw.Text(
                  'No medication actions or possible-fall alerts were saved in this period.',
                  style: const pw.TextStyle(fontSize: 8, color: muted),
                ),
              )
            else
              pw.TableHelper.fromTextArray(
                headers: const <String>[
                  'Date',
                  'Taken',
                  'Missed',
                  'Unresolved',
                  'Alerts',
                  'Completion',
                ],
                data: <List<String>>[
                  for (final day in recentDays)
                    <String>[
                      _date(day.date),
                      '${day.taken}',
                      '${day.missed}',
                      '${day.unresolved}',
                      '${day.alerts}',
                      day.completion == null
                          ? '—'
                          : '${day.completion!.toStringAsFixed(0)}%',
                    ],
                ],
                headerDecoration: const pw.BoxDecoration(color: orange),
                headerStyle: pw.TextStyle(
                  color: PdfColors.white,
                  fontSize: 7,
                  fontWeight: pw.FontWeight.bold,
                ),
                cellStyle: const pw.TextStyle(fontSize: 7, color: dark),
                cellAlignment: pw.Alignment.center,
                oddRowDecoration: const pw.BoxDecoration(color: pale),
                border: pw.TableBorder.all(color: border, width: 0.5),
                cellPadding: const pw.EdgeInsets.symmetric(
                  horizontal: 3,
                  vertical: 3,
                ),
              ),
            pw.SizedBox(height: 10),
            _heading('Smart Insights', dark),
            pw.SizedBox(height: 5),
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.all(9),
              decoration: pw.BoxDecoration(
                color: pale,
                borderRadius: pw.BorderRadius.circular(8),
                border: pw.Border.all(color: border),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Expanded(
                        child: pw.Text(
                          insights.headline,
                          style: pw.TextStyle(
                            fontSize: 10,
                            fontWeight: pw.FontWeight.bold,
                            color: dark,
                          ),
                        ),
                      ),
                      pw.Text(
                        '${insights.confidenceLabel} data confidence',
                        style: pw.TextStyle(
                          fontSize: 7.5,
                          fontWeight: pw.FontWeight.bold,
                          color: orange,
                        ),
                      ),
                    ],
                  ),
                  pw.SizedBox(height: 2),
                  pw.Text(
                    insights.summary,
                    style: const pw.TextStyle(fontSize: 7.5, color: muted),
                  ),
                  pw.SizedBox(height: 5),
                  for (final item in insights.items.take(3))
                    pw.Padding(
                      padding: const pw.EdgeInsets.only(bottom: 3),
                      child: pw.RichText(
                        text: pw.TextSpan(
                          style: const pw.TextStyle(
                            fontSize: 7.5,
                            color: muted,
                          ),
                          children: [
                            pw.TextSpan(
                              text: '• ${item.title}: ',
                              style: pw.TextStyle(
                                color: dark,
                                fontWeight: pw.FontWeight.bold,
                              ),
                            ),
                            pw.TextSpan(text: item.body),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            pw.SizedBox(height: 9),
            _heading('Next 7 days completion outlook', dark),
            pw.SizedBox(height: 4),
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.symmetric(
                horizontal: 9,
                vertical: 7,
              ),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: border),
                borderRadius: pw.BorderRadius.circular(7),
              ),
              child: pw.Text(
                outlook == null
                    ? 'More history is needed: at least 7 completed days with dose records and 14 recorded doses.'
                    : 'Around ${outlook.percent.toStringAsFixed(0)}% if recording habits and schedules stay similar. Historical 95% range: ${outlook.lower.toStringAsFixed(0)}–${outlook.upper.toStringAsFixed(0)}%, based on ${outlook.recordDays} completed days.',
                style: const pw.TextStyle(fontSize: 7.8, color: muted),
              ),
            ),
            pw.Spacer(),
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.only(top: 6),
              decoration: const pw.BoxDecoration(
                border: pw.Border(
                  top: pw.BorderSide(color: border, width: 0.5),
                ),
              ),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Expanded(
                    child: pw.Text(
                      'Saved records only. No record does not prove no medication was due or no fall occurred. Alert events are sensor detections, not confirmed falls. The outlook is a historical estimate, not a diagnosis or fall prediction.',
                      style: const pw.TextStyle(
                        fontSize: 6.5,
                        color: muted,
                        height: 1.15,
                      ),
                    ),
                  ),
                  pw.SizedBox(width: 8),
                  pw.Text(
                    'SHCA • 1-page summary',
                    style: pw.TextStyle(
                      fontSize: 6.5,
                      color: dark,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return document.save();
  }

  Future<bool> shareReport({
    required String personName,
    required HealthStatistics statistics,
    required bool fromCache,
  }) async {
    final bytes = await buildReport(
      personName: personName,
      statistics: statistics,
      fromCache: fromCache,
    );
    final safeName = personName
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final filename =
        'shca-statistics-${safeName.isEmpty ? 'report' : safeName}-${_fileDate(statistics.asOf)}.pdf';
    return Printing.sharePdf(
      bytes: bytes,
      filename: filename,
      subject: 'SHCA health statistics report',
      body:
          'Recorded statistics for ${_date(statistics.start)} – ${_date(statistics.asOf)}.',
    );
  }

  static pw.Widget _heading(String text, PdfColor color) => pw.Text(
    text,
    style: pw.TextStyle(
      color: color,
      fontSize: 11,
      fontWeight: pw.FontWeight.bold,
    ),
  );

  static pw.Widget _metric(
    String label,
    String value,
    PdfColor accent,
    PdfColor border,
  ) => pw.Expanded(
    child: pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: border),
        borderRadius: pw.BorderRadius.circular(7),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            value,
            style: pw.TextStyle(
              color: accent,
              fontSize: 15,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          pw.SizedBox(height: 2),
          pw.Text(label, style: const pw.TextStyle(fontSize: 7)),
        ],
      ),
    ),
  );

  static pw.Widget _breakdown({
    required String title,
    required List<MapEntry<String, int>> values,
    required PdfColor pale,
    required PdfColor border,
    required PdfColor dark,
    required PdfColor muted,
  }) => pw.Container(
    padding: const pw.EdgeInsets.all(8),
    decoration: pw.BoxDecoration(
      color: pale,
      borderRadius: pw.BorderRadius.circular(7),
      border: pw.Border.all(color: border),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          title,
          style: pw.TextStyle(
            color: dark,
            fontSize: 8.5,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        pw.SizedBox(height: 4),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            for (final value in values)
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    '${value.value}',
                    style: pw.TextStyle(
                      color: dark,
                      fontSize: 10,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    value.key,
                    style: pw.TextStyle(fontSize: 6.5, color: muted),
                  ),
                ],
              ),
          ],
        ),
      ],
    ),
  );

  static String _date(DateTime value) {
    final local = value.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/${local.month.toString().padLeft(2, '0')}/${local.year}';
  }

  static String _fileDate(DateTime value) {
    final local = value.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }
}
