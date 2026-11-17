using Microsoft.AspNetCore.Mvc;

namespace FlexContainerHtmlToPdf.Tests;

public sealed class HelloTests
{
    [Fact]
    public void ReturnsExpectedResponse()
    {
        var result = Assert.IsType<ContentResult>(Hello.Run(null!));

        Assert.Equal(200, result.StatusCode);
        Assert.Equal("text/plain", result.ContentType);
        Assert.Equal("Hello from the .NET worker.", result.Content);
    }
}
