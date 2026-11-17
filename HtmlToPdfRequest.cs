using System.Net;
using System.Net.Http.Headers;
using System.Text;

internal sealed record PdfDocumentRequest(string Html, string FileName);

internal sealed class PdfRequestValidationException(
    HttpStatusCode statusCode,
    string code,
    string message) : Exception(message)
{
    public HttpStatusCode StatusCode { get; } = statusCode;

    public string Code { get; } = code;
}

internal static class HtmlToPdfRequestParser
{
    internal const int MaxHtmlBytes = 1024 * 1024;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    internal static PdfDocumentRequest FromGet() =>
        new(SampleInvoice.Html, "sample-invoice.pdf");

    internal static PdfDocumentRequest FromPost(string? contentType, ReadOnlySpan<byte> body)
    {
        if (!MediaTypeHeaderValue.TryParse(contentType, out var mediaType) ||
            !string.Equals(mediaType.MediaType, "text/html", StringComparison.OrdinalIgnoreCase))
        {
            throw new PdfRequestValidationException(
                HttpStatusCode.UnsupportedMediaType,
                "unsupported_media_type",
                "POST requests must use Content-Type: text/html.");
        }

        if (body.Length == 0)
        {
            throw new PdfRequestValidationException(
                HttpStatusCode.BadRequest,
                "empty_html",
                "The HTML request body cannot be empty.");
        }

        if (body.Length > MaxHtmlBytes)
        {
            throw new PdfRequestValidationException(
                HttpStatusCode.RequestEntityTooLarge,
                "html_too_large",
                $"The HTML request body cannot exceed {MaxHtmlBytes} bytes.");
        }

        string html;
        try
        {
            html = StrictUtf8.GetString(body);
        }
        catch (DecoderFallbackException)
        {
            throw new PdfRequestValidationException(
                HttpStatusCode.BadRequest,
                "invalid_utf8",
                "The HTML request body must be valid UTF-8.");
        }

        if (string.IsNullOrWhiteSpace(html))
        {
            throw new PdfRequestValidationException(
                HttpStatusCode.BadRequest,
                "empty_html",
                "The HTML request body cannot be empty.");
        }

        return new PdfDocumentRequest(html, "document.pdf");
    }
}
