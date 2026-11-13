using PuppeteerSharp;
using PuppeteerSharp.Media;
using UglyToad.PdfPig;

public sealed class PdfRenderer
{
    internal const int MaxPdfBytes = 10 * 1024 * 1024;
    internal const int MaxPages = 20;
    private const int RenderTimeoutSeconds = 30;
    private const int BrowserLaunchTimeoutMilliseconds = 15_000;
    private const int PageOperationTimeoutMilliseconds = 15_000;
    private const string DefaultChromiumPath = "/usr/bin/chromium-headless-shell";
    private static readonly byte[] PdfHeader = "%PDF-"u8.ToArray();
    private static readonly byte[] PdfTrailer = "%%EOF"u8.ToArray();
    private readonly SemaphoreSlim renderSlot = new(1, 1);

    public async Task<byte[]> RenderAsync(string html, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(RenderTimeoutSeconds));

        var slotAcquired = false;
        try
        {
            await renderSlot.WaitAsync(timeout.Token);
            slotAcquired = true;

            var pdf = await RenderCoreAsync(html, timeout.Token);
            ValidatePdf(pdf);
            return pdf;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new PdfRenderTimeoutException(
                $"Rendering did not complete within {RenderTimeoutSeconds} seconds.");
        }
        catch (PdfRenderException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new PdfRenderException("Chromium failed while generating the PDF.", exception);
        }
        finally
        {
            if (slotAcquired)
            {
                renderSlot.Release();
            }
        }
    }

    internal static bool IsAllowedResourceUrl(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri))
        {
            return false;
        }

        return uri.Scheme.Equals("about", StringComparison.OrdinalIgnoreCase) ||
            uri.Scheme.Equals("blob", StringComparison.OrdinalIgnoreCase) ||
            uri.Scheme.Equals("data", StringComparison.OrdinalIgnoreCase);
    }

    internal static void ValidatePdf(byte[] pdf)
    {
        if (pdf.Length > MaxPdfBytes)
        {
            throw new PdfRenderLimitException(
                $"The generated PDF cannot exceed {MaxPdfBytes} bytes.");
        }

        if (!pdf.AsSpan().StartsWith(PdfHeader) ||
            pdf.AsSpan(Math.Max(0, pdf.Length - 1024)).IndexOf(PdfTrailer) < 0)
        {
            throw new PdfRenderException("Chromium returned an invalid PDF payload.");
        }

        try
        {
            using var document = PdfDocument.Open(pdf);
            if (document.NumberOfPages == 0)
            {
                throw new PdfRenderException("Chromium returned a PDF with no pages.");
            }

            if (document.NumberOfPages > MaxPages)
            {
                throw new PdfRenderLimitException(
                    $"The generated PDF cannot exceed {MaxPages} pages.");
            }
        }
        catch (PdfRenderException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new PdfRenderException("The generated PDF could not be validated.", exception);
        }
    }

    private static async Task<byte[]> RenderCoreAsync(
        string html,
        CancellationToken cancellationToken)
    {
        var chromiumPath =
            Environment.GetEnvironmentVariable("CHROMIUM_EXECUTABLE_PATH") ??
            DefaultChromiumPath;

        if (!File.Exists(chromiumPath))
        {
            throw new PdfRenderException($"Chromium was not found at '{chromiumPath}'.");
        }

        var launchOptions = new LaunchOptions
        {
            Browser = SupportedBrowser.Chrome,
            ExecutablePath = chromiumPath,
            Headless = true,
            HeadlessMode = HeadlessMode.Shell,
            Timeout = BrowserLaunchTimeoutMilliseconds,
            Args =
            [
                "--disable-background-networking",
                "--disable-component-update",
                "--disable-default-apps",
                "--disable-dev-shm-usage",
                "--disable-extensions",
                "--disable-gpu",
                "--disable-sync",
                "--metrics-recording-only",
                "--no-first-run",
                "--proxy-server=http://127.0.0.1:9",
                "--proxy-bypass-list=<-loopback>",
            ],
        };

        await using var browser =
            await Puppeteer.LaunchAsync(launchOptions).WaitAsync(cancellationToken);
        await using var page =
            await browser.NewPageAsync().WaitAsync(cancellationToken);

        await page.SetJavaScriptEnabledAsync(false).WaitAsync(cancellationToken);
        await page.SetRequestInterceptionAsync(true).WaitAsync(cancellationToken);
        page.AddRequestInterceptor(request =>
            IsAllowedResourceUrl(request.Url)
                ? request.ContinueAsync()
                : request.AbortAsync(RequestAbortErrorCode.BlockedByClient));

        await page.SetContentAsync(
            html,
            new SetContentOptions
            {
                CancellationToken = cancellationToken,
                Timeout = PageOperationTimeoutMilliseconds,
                WaitUntil = [WaitUntilNavigation.DOMContentLoaded],
            });

        return await page.PdfDataAsync(
            new PdfOptions
            {
                Format = PaperFormat.A4,
                MarginOptions = new MarginOptions
                {
                    Top = "12mm",
                    Right = "12mm",
                    Bottom = "12mm",
                    Left = "12mm",
                },
                PreferCSSPageSize = true,
                PrintBackground = true,
                Tagged = true,
                Timeout = PageOperationTimeoutMilliseconds,
                WaitForFonts = true,
            }).WaitAsync(cancellationToken);
    }
}

public class PdfRenderException(string message, Exception? innerException = null)
    : Exception(message, innerException);

public sealed class PdfRenderLimitException(string message)
    : PdfRenderException(message);

public sealed class PdfRenderTimeoutException(string message)
    : PdfRenderException(message);
