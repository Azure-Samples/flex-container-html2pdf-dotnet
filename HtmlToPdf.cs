using System.Buffers;
using System.Net;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

public sealed class HtmlToPdf(PdfRenderer renderer, ILogger<HtmlToPdf> logger)
{
    [Function(nameof(HtmlToPdf))]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", "post", Route = "html-to-pdf")]
        HttpRequest request,
        CancellationToken cancellationToken)
    {
        try
        {
            var documentRequest = request.Method.Equals("GET", StringComparison.OrdinalIgnoreCase)
                ? HtmlToPdfRequestParser.FromGet()
                : HtmlToPdfRequestParser.FromPost(
                    request.ContentType,
                    await ReadBodyAsync(request.Body, cancellationToken));

            var pdf = await renderer.RenderAsync(documentRequest.Html, cancellationToken);

            request.HttpContext.Response.Headers.CacheControl = "no-store";
            request.HttpContext.Response.Headers.XContentTypeOptions = "nosniff";

            return new FileContentResult(pdf, "application/pdf")
            {
                FileDownloadName = documentRequest.FileName,
            };
        }
        catch (PdfRequestValidationException exception)
        {
            return Error(exception.StatusCode, exception.Code, exception.Message);
        }
        catch (PdfRenderLimitException exception)
        {
            return Error(
                HttpStatusCode.UnprocessableEntity,
                "render_limit_exceeded",
                exception.Message);
        }
        catch (PdfRenderTimeoutException exception)
        {
            return Error(HttpStatusCode.GatewayTimeout, "render_timeout", exception.Message);
        }
        catch (OperationCanceledException) when (request.HttpContext.RequestAborted.IsCancellationRequested)
        {
            return Error(
                HttpStatusCode.RequestTimeout,
                "request_cancelled",
                "The request was cancelled before rendering completed.");
        }
        catch (PdfRenderException exception)
        {
            logger.LogError(exception, "HTML-to-PDF rendering failed.");
            return Error(
                HttpStatusCode.InternalServerError,
                "render_failed",
                "The PDF could not be generated.");
        }
    }

    private static ObjectResult Error(HttpStatusCode statusCode, string code, string message) =>
        new(new { error = code, message })
        {
            StatusCode = (int)statusCode,
        };

    private static async Task<byte[]> ReadBodyAsync(
        Stream requestBody,
        CancellationToken cancellationToken)
    {
        var buffer = ArrayPool<byte>.Shared.Rent(64 * 1024);
        try
        {
            using var body = new MemoryStream();
            while (true)
            {
                var bytesRead = await requestBody.ReadAsync(buffer, cancellationToken);
                if (bytesRead == 0)
                {
                    return body.ToArray();
                }

                if (body.Length + bytesRead > HtmlToPdfRequestParser.MaxHtmlBytes)
                {
                    throw new PdfRequestValidationException(
                        HttpStatusCode.RequestEntityTooLarge,
                        "html_too_large",
                        $"The HTML request body cannot exceed {HtmlToPdfRequestParser.MaxHtmlBytes} bytes.");
                }

                body.Write(buffer, 0, bytesRead);
            }
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }
    }
}
