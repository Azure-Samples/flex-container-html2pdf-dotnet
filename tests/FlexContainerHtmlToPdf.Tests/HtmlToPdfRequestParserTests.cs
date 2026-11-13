using System.Net;
using System.Text;

namespace FlexContainerHtmlToPdf.Tests;

public sealed class HtmlToPdfRequestParserTests
{
    [Fact]
    public void GetUsesBuiltInInvoice()
    {
        var request = HtmlToPdfRequestParser.FromGet();

        Assert.Equal("sample-invoice.pdf", request.FileName);
        Assert.Equal(SampleInvoice.Html, request.Html);
    }

    [Fact]
    public void PostAcceptsUtf8Html()
    {
        const string html = "<h1>Hello, PDF</h1>";

        var request = HtmlToPdfRequestParser.FromPost(
            "text/html; charset=utf-8",
            Encoding.UTF8.GetBytes(html));

        Assert.Equal("document.pdf", request.FileName);
        Assert.Equal(html, request.Html);
    }

    [Fact]
    public void PostRejectsWrongContentType()
    {
        var exception = Assert.Throws<PdfRequestValidationException>(() =>
            HtmlToPdfRequestParser.FromPost(
                "application/json",
                "{}"u8));

        Assert.Equal(HttpStatusCode.UnsupportedMediaType, exception.StatusCode);
        Assert.Equal("unsupported_media_type", exception.Code);
    }

    [Fact]
    public void PostRejectsEmptyHtml()
    {
        var exception = Assert.Throws<PdfRequestValidationException>(() =>
            HtmlToPdfRequestParser.FromPost(
                "text/html",
                "   "u8));

        Assert.Equal(HttpStatusCode.BadRequest, exception.StatusCode);
        Assert.Equal("empty_html", exception.Code);
    }

    [Fact]
    public void PostRejectsInvalidUtf8()
    {
        var exception = Assert.Throws<PdfRequestValidationException>(() =>
            HtmlToPdfRequestParser.FromPost(
                "text/html",
                new byte[] { 0xc3, 0x28 }));

        Assert.Equal(HttpStatusCode.BadRequest, exception.StatusCode);
        Assert.Equal("invalid_utf8", exception.Code);
    }

    [Fact]
    public void PostRejectsOversizedHtml()
    {
        var exception = Assert.Throws<PdfRequestValidationException>(() =>
            HtmlToPdfRequestParser.FromPost(
                "text/html",
                new byte[HtmlToPdfRequestParser.MaxHtmlBytes + 1]));

        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, exception.StatusCode);
        Assert.Equal("html_too_large", exception.Code);
    }
}
