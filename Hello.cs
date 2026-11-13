// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;

namespace FlexContainerHtmlToPdf;

public static class Hello
{
    [Function(nameof(Hello))]
    public static IActionResult Run([HttpTrigger(AuthorizationLevel.Anonymous, "get", "post", Route = "hello")] HttpRequest req)
    {
        return new ContentResult
        {
            Content = "Hello from the .NET worker.",
            ContentType = "text/plain",
            StatusCode = StatusCodes.Status200OK,
        };
    }
}
