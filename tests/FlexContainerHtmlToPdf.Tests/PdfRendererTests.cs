namespace FlexContainerHtmlToPdf.Tests;

public sealed class PdfRendererTests
{
    [Theory]
    [InlineData("about:blank")]
    [InlineData("data:image/png;base64,AA==")]
    [InlineData("blob:null/8a50b368-a105-4c51-8db5-578a309f9463")]
    public void AllowsEmbeddedResources(string url) =>
        Assert.True(PdfRenderer.IsAllowedResourceUrl(url));

    [Theory]
    [InlineData("https://example.com/image.png")]
    [InlineData("http://127.0.0.1:8080/private")]
    [InlineData("file:///etc/passwd")]
    [InlineData("ftp://example.com/file")]
    [InlineData("ws://example.com/socket")]
    [InlineData("/relative/image.png")]
    public void BlocksExternalResources(string url) =>
        Assert.False(PdfRenderer.IsAllowedResourceUrl(url));

    [Fact]
    public void RejectsNonPdfPayload()
    {
        var exception = Assert.Throws<PdfRenderException>(() =>
            PdfRenderer.ValidatePdf("not a pdf"u8.ToArray()));

        Assert.Contains("invalid PDF", exception.Message);
    }

    [Fact]
    public void RejectsOversizedPayload()
    {
        var exception = Assert.Throws<PdfRenderLimitException>(() =>
            PdfRenderer.ValidatePdf(new byte[PdfRenderer.MaxPdfBytes + 1]));

        Assert.Contains("cannot exceed", exception.Message);
    }
}
