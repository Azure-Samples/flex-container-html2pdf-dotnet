using System.Net;
using System.Net.Sockets;
using System.Text;
using UglyToad.PdfPig;

var renderer = new PdfRenderer();
var invoicePdf = await renderer.RenderAsync(SampleInvoice.Html, CancellationToken.None);
var invoicePages = ValidatePdf(invoicePdf);

var outputPath = Environment.GetEnvironmentVariable("PDF_OUTPUT_PATH");
if (!string.IsNullOrWhiteSpace(outputPath))
{
    var directory = Path.GetDirectoryName(outputPath);
    if (!string.IsNullOrEmpty(directory))
    {
        Directory.CreateDirectory(directory);
    }

    await File.WriteAllBytesAsync(outputPath, invoicePdf);
}

using var listener = new TcpListener(IPAddress.Loopback, 0);
listener.Start();
var listenerPort = ((IPEndPoint)listener.LocalEndpoint).Port;
using var listenerCancellation = new CancellationTokenSource();
var connectionAttempt = listener.AcceptTcpClientAsync(listenerCancellation.Token).AsTask();

var isolatedHtml = $$"""
    <!doctype html>
    <html>
    <body>
      <p id="status">JavaScript stayed disabled.</p>
      <img alt="embedded" src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='1' height='1'%3E%3C/svg%3E">
      <img alt="blocked" src="http://127.0.0.1:{{listenerPort}}/private.png">
      <script>document.getElementById('status').textContent = 'JavaScript executed.';</script>
    </body>
    </html>
    """;

var isolatedPdf = await renderer.RenderAsync(isolatedHtml, CancellationToken.None);
var isolatedText = ExtractText(isolatedPdf);
await Task.Delay(250);
if (connectionAttempt.IsCompletedSuccessfully)
{
    using var connection = await connectionAttempt;
    throw new InvalidOperationException("Chromium reached a blocked external resource.");
}

listenerCancellation.Cancel();
listener.Stop();
try
{
    await connectionAttempt;
}
catch (OperationCanceledException)
{
}

if (!isolatedText.Contains("JavaScript stayed disabled.", StringComparison.Ordinal) ||
    isolatedText.Contains("JavaScript executed.", StringComparison.Ordinal))
{
    throw new InvalidOperationException("JavaScript executed while rendering untrusted HTML.");
}

var pages = new StringBuilder("""
    <!doctype html>
    <html>
    <head><style>.page { break-after: page; } .page:last-child { break-after: auto; }</style></head>
    <body>
    """);
for (var index = 1; index <= 21; index++)
{
    pages.Append($"<section class=\"page\"><h1>Page {index}</h1></section>");
}

pages.Append("</body></html>");
try
{
    await renderer.RenderAsync(pages.ToString(), CancellationToken.None);
    throw new InvalidOperationException("A PDF over the 20-page limit was accepted.");
}
catch (PdfRenderLimitException)
{
}

Console.WriteLine(
    $"Validated a {invoicePages}-page invoice PDF ({invoicePdf.Length} bytes), JavaScript isolation, external-resource blocking, and the 20-page limit without disabling Chromium's sandbox.");

static int ValidatePdf(byte[] pdf)
{
    using var document = PdfDocument.Open(pdf);
    if (document.NumberOfPages is < 1 or > 20)
    {
        throw new InvalidOperationException(
            $"Expected 1-20 pages, but Chromium produced {document.NumberOfPages}.");
    }

    return document.NumberOfPages;
}

static string ExtractText(byte[] pdf)
{
    using var document = PdfDocument.Open(pdf);
    return string.Join(Environment.NewLine, document.GetPages().Select(page => page.Text));
}
