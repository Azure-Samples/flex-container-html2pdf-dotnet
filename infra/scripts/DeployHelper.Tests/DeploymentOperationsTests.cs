using System.Text;
using System.Text.Json;
using DeployHelper;

public sealed class DeploymentOperationsTests
{
    [Fact]
    public void StageContextContainsOnlyRuntimeImageInputs()
    {
        var repository = MakeRepository();
        var publish = MakePublishRoot();
        var destination = TemporaryPath();

        try
        {
            DeploymentOperations.PrepareImageContext(
                repository,
                destination,
                publish);

            Assert.True(File.Exists(Path.Combine(
                destination,
                "dotnet10.Dockerfile")));
            Assert.True(File.Exists(Path.Combine(
                destination,
                "publish",
                "app",
                "FlexContainerHtmlToPdf.dll")));
            Assert.True(File.Exists(Path.Combine(
                destination,
                "publish",
                "rendercheck",
                "RenderCheck.dll")));
            Assert.False(File.Exists(Path.Combine(destination, "README.md")));
            Assert.False(File.Exists(Path.Combine(destination, "Program.cs")));
        }
        finally
        {
            DeleteDirectory(repository);
            DeleteDirectory(publish);
            DeleteDirectory(destination);
        }
    }

    [Fact]
    public void EquivalentPublishedOutputsProduceTheSameHash()
    {
        var firstRepository = MakeRepository();
        var secondRepository = MakeRepository();
        var firstPublish = MakePublishRoot();
        var secondPublish = MakePublishRoot();

        try
        {
            Assert.Equal(
                PrepareAndHash(firstRepository, firstPublish),
                PrepareAndHash(secondRepository, secondPublish));
        }
        finally
        {
            DeleteDirectory(firstRepository);
            DeleteDirectory(secondRepository);
            DeleteDirectory(firstPublish);
            DeleteDirectory(secondPublish);
        }
    }

    [Fact]
    public void UnrelatedSourceFileDoesNotChangeHash()
    {
        var firstRepository = MakeRepository();
        var secondRepository = MakeRepository();
        var firstPublish = MakePublishRoot();
        var secondPublish = MakePublishRoot();

        try
        {
            File.WriteAllText(
                Path.Combine(secondRepository, "README.md"),
                "changed",
                Encoding.UTF8);
            Assert.Equal(
                PrepareAndHash(firstRepository, firstPublish),
                PrepareAndHash(secondRepository, secondPublish));
        }
        finally
        {
            DeleteDirectory(firstRepository);
            DeleteDirectory(secondRepository);
            DeleteDirectory(firstPublish);
            DeleteDirectory(secondPublish);
        }
    }

    [Fact]
    public void PublishedApplicationChangeDoesNotChangeSourceHash()
    {
        var repository = MakeRepository();
        var firstPublish = MakePublishRoot();
        var secondPublish = MakePublishRoot();

        try
        {
            File.WriteAllText(
                Path.Combine(
                    secondPublish,
                    "app",
                    "FlexContainerHtmlToPdf.dll"),
                "changed",
                Encoding.UTF8);
            Assert.Equal(
                PrepareAndHash(repository, firstPublish),
                PrepareAndHash(repository, secondPublish));
        }
        finally
        {
            DeleteDirectory(repository);
            DeleteDirectory(firstPublish);
            DeleteDirectory(secondPublish);
        }
    }

    [Fact]
    public void SourceChangeChangesHash()
    {
        var firstRepository = MakeRepository();
        var secondRepository = MakeRepository();
        var firstPublish = MakePublishRoot();
        var secondPublish = MakePublishRoot();

        try
        {
            File.WriteAllText(
                Path.Combine(
                    secondRepository,
                    "Hello.cs"),
                "changed",
                Encoding.UTF8);
            Assert.NotEqual(
                PrepareAndHash(firstRepository, firstPublish),
                PrepareAndHash(secondRepository, secondPublish));
        }
        finally
        {
            DeleteDirectory(firstRepository);
            DeleteDirectory(secondRepository);
            DeleteDirectory(firstPublish);
            DeleteDirectory(secondPublish);
        }
    }

    [Fact]
    public void TestChangeChangesHash()
    {
        var firstRepository = MakeRepository();
        var secondRepository = MakeRepository();
        var firstPublish = MakePublishRoot();
        var secondPublish = MakePublishRoot();

        try
        {
            File.WriteAllText(
                Path.Combine(
                    secondRepository,
                    "tests",
                    "FlexContainerHtmlToPdf.Tests",
                    "SampleTests.cs"),
                "changed",
                Encoding.UTF8);
            Assert.NotEqual(
                PrepareAndHash(firstRepository, firstPublish),
                PrepareAndHash(secondRepository, secondPublish));
        }
        finally
        {
            DeleteDirectory(firstRepository);
            DeleteDirectory(secondRepository);
            DeleteDirectory(firstPublish);
            DeleteDirectory(secondPublish);
        }
    }

    [Fact]
    public void MissingRequiredDockerfileFails()
    {
        var repository = MakeRepository();
        var publish = MakePublishRoot();
        var destination = TemporaryPath();

        try
        {
            File.Delete(Path.Combine(repository, "dotnet10.Dockerfile"));
            Assert.Throws<FileNotFoundException>(() =>
                DeploymentOperations.PrepareImageContext(
                    repository,
                    destination,
                    publish));
        }
        finally
        {
            DeleteDirectory(repository);
            DeleteDirectory(publish);
            DeleteDirectory(destination);
        }
    }

    [Fact]
    public void MissingPublishedApplicationFails()
    {
        var repository = MakeRepository();
        var publish = MakePublishRoot();
        var destination = TemporaryPath();

        try
        {
            File.Delete(Path.Combine(
                publish,
                "app",
                "FlexContainerHtmlToPdf.dll"));
            Assert.Throws<FileNotFoundException>(() =>
                DeploymentOperations.PrepareImageContext(
                    repository,
                    destination,
                    publish));
        }
        finally
        {
            DeleteDirectory(repository);
            DeleteDirectory(publish);
            DeleteDirectory(destination);
        }
    }

    [Fact]
    public void NonEmptyDestinationFails()
    {
        var repository = MakeRepository();
        var publish = MakePublishRoot();
        var destination = TemporaryPath();
        Directory.CreateDirectory(destination);
        File.WriteAllText(Path.Combine(destination, "existing.txt"), "existing");

        try
        {
            Assert.Throws<InvalidOperationException>(() =>
                DeploymentOperations.PrepareImageContext(
                    repository,
                    destination,
                    publish));
        }
        finally
        {
            DeleteDirectory(repository);
            DeleteDirectory(publish);
            DeleteDirectory(destination);
        }
    }

    [Fact]
    public void SymbolicLinkInputFailsWhenSupported()
    {
        var repository = MakeRepository();
        var publish = MakePublishRoot();
        var destination = TemporaryPath();
        var link = Path.Combine(
            publish,
            "app",
            "FlexContainerHtmlToPdf.dll");

        try
        {
            File.Delete(link);
            try
            {
                File.CreateSymbolicLink(
                    link,
                    Path.Combine(publish, "app", "FlexContainerHtmlToPdf.deps.json"));
            }
            catch (Exception exception) when (
                exception is UnauthorizedAccessException or
                PlatformNotSupportedException or
                IOException)
            {
                return;
            }

            var failure = Assert.Throws<InvalidOperationException>(() =>
                DeploymentOperations.PrepareImageContext(
                    repository,
                    destination,
                    publish));
            Assert.Contains("Symbolic links", failure.Message);
        }
        finally
        {
            DeleteDirectory(repository);
            DeleteDirectory(publish);
            DeleteDirectory(destination);
        }
    }

    [Fact]
    public void ValidatePdfAcceptsPdfBoundaries()
    {
        var path = Path.GetTempFileName();
        try
        {
            var content = new List<byte>("%PDF-1.7\n"u8.ToArray());
            content.AddRange(new byte[128]);
            content.AddRange("\n%%EOF\n"u8.ToArray());
            File.WriteAllBytes(path, content.ToArray());

            Assert.Equal(content.Count, DeploymentOperations.ValidatePdf(path));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void WriteParametersUsesEnvironmentAndSecureMode()
    {
        var values = ParameterEnvironment();
        using var environment = new EnvironmentScope(values);
        var path = Path.Combine(Path.GetTempPath(), $"{Guid.NewGuid():N}.json");

        try
        {
            DeploymentOperations.WriteParameters(path);
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            Assert.Equal(
                values["REGISTRY_IMAGE"],
                document.RootElement
                    .GetProperty("parameters")
                    .GetProperty("registryImage")
                    .GetProperty("value")
                    .GetString());
            Assert.DoesNotContain(
                "AZURE_SUBSCRIPTION_ID",
                File.ReadAllText(path),
                StringComparison.Ordinal);

            if (!OperatingSystem.IsWindows())
            {
                Assert.Equal(
                    UnixFileMode.UserRead | UnixFileMode.UserWrite,
                    File.GetUnixFileMode(path));
            }
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void ValidateSiteAcceptsExpectedSecureConfiguration()
    {
        using var environment = new EnvironmentScope(new Dictionary<string, string>
        {
            ["AZURE_REGISTRY_IMAGE"] =
                "registry.example/repository:tag@sha256:digest",
            ["AZURE_FUNCTION_SUBNET_ID"] = "/subnets/function",
            ["AZURE_USER_ASSIGNED_IDENTITY_ID"] = "/identities/function",
            ["SITE_JSON"] = """
                {
                  "state": "Running",
                  "type": "Registry",
                  "value": "registry.example/repository:tag@sha256:digest",
                  "subnet": "/subnets/function",
                  "identityType": "UserAssigned",
                  "identityIds": ["/identities/function"],
                  "httpsOnly": true
                }
                """,
            ["WEB_CONFIG_JSON"] = """
                {
                  "minTlsVersion": "1.2",
                  "scmMinTlsVersion": "1.2",
                  "ftpsState": "Disabled",
                  "http20Enabled": true,
                  "remoteDebuggingEnabled": false
                }
                """,
            ["FTP_POLICY_JSON"] = """{"properties":{"allow":false}}""",
            ["SCM_POLICY_JSON"] = """{"properties":{"allow":false}}""",
        });

        DeploymentOperations.ValidateSite();
    }

    [Fact]
    public void ValidateSiteAcceptsSingleIdentityString()
    {
        using var environment = new EnvironmentScope(new Dictionary<string, string>
        {
            ["AZURE_REGISTRY_IMAGE"] =
                "registry.example/repository:tag@sha256:digest",
            ["AZURE_FUNCTION_SUBNET_ID"] = "/subnets/function",
            ["AZURE_USER_ASSIGNED_IDENTITY_ID"] = "/identities/function",
            ["SITE_JSON"] = """
                {
                  "state": "Running",
                  "type": "Registry",
                  "value": "registry.example/repository:tag@sha256:digest",
                  "subnet": "/subnets/function",
                  "identityType": "UserAssigned",
                  "identityIds": "/identities/function",
                  "httpsOnly": true
                }
                """,
            ["WEB_CONFIG_JSON"] = """
                {
                  "minTlsVersion": "1.2",
                  "scmMinTlsVersion": "1.2",
                  "ftpsState": "Disabled",
                  "http20Enabled": true,
                  "remoteDebuggingEnabled": false
                }
                """,
            ["FTP_POLICY_JSON"] = """{"properties":{"allow":false}}""",
            ["SCM_POLICY_JSON"] = """{"properties":{"allow":false}}""",
        });

        DeploymentOperations.ValidateSite();
    }

    [Fact]
    public void TraceContextUsesW3CLengths()
    {
        var trace = DeploymentOperations.CreateTraceContext();

        Assert.Matches("^[0-9a-f]{32}$", trace.TraceId);
        Assert.Matches(
            $"^00-{trace.TraceId}-[0-9a-f]{{16}}-01$",
            trace.TraceParent);
    }

    [Fact]
    public void VerificationJsonModelContainsDeploymentEvidence()
    {
        var values = ParameterEnvironment();
        values.Add(
            "AZURE_REGISTRY_IMAGE",
            values["REGISTRY_IMAGE"]);
        values.Add("AZURE_IMAGE_CONTEXT_HASH", new string('a', 64));
        values.Add("AZURE_IMAGE_BUILD_ACTION", "built");
        values.Add("AZURE_IMAGE_DIGEST", $"sha256:{new string('b', 64)}");
        values.Add("LEAF_NAMES", "Hello\nHtmlToPdf");
        values.Add("HELLO_GET_STATUS", "200");
        values.Add("HELLO_POST_STATUS", "200");
        values.Add("PDF_GET_BYTES", "1000");
        values.Add("PDF_POST_BYTES", "2000");
        values.Add("INVALID_STATUS", "415");
        values.Add("APPINSIGHTS_REQUEST_COUNT", "5");
        values.Add("APPINSIGHTS_FAILED_REQUEST_COUNT", "0");
        values.Add("STORAGE_ROLE_VERIFIED", "true");
        values.Add("MONITORING_ROLE_VERIFIED", "true");
        values.Add("VERIFIED_UTC", "2026-11-13T00:00:00Z");
        using var environment = new EnvironmentScope(values);

        var result = DeploymentOperations.BuildVerificationResult();

        Assert.Equal(["Hello", "HtmlToPdf"], result.Functions);
        Assert.Equal(0, result.ApplicationInsightsFailedRequestCount);
        Assert.True(result.StorageRoleVerified);
        Assert.True(result.MonitoringRoleVerified);
    }

    private static string MakeRepository()
    {
        var root = TemporaryPath();
        var files = new Dictionary<string, string>
        {
            [".dockerignore"] = "*\n!dotnet10.Dockerfile\n!publish/**\n",
            ["dotnet10.Dockerfile"] = "FROM scratch\nCOPY publish/app/ ./\n",
            ["FlexContainerHtmlToPdf.csproj"] = "<Project />\n",
            ["host.json"] = """{"version":"2.0"}""" + "\n",
            ["NuGet.config"] = "<configuration />\n",
            ["AssemblyInfo.cs"] = "using System;\n",
            ["Hello.cs"] = "public static class Hello {}\n",
            [Path.Combine(
                "tests",
                "FlexContainerHtmlToPdf.Tests",
                "FlexContainerHtmlToPdf.Tests.csproj")] = "<Project />\n",
            [Path.Combine(
                "tests",
                "FlexContainerHtmlToPdf.Tests",
                "SampleTests.cs")] = "public static class Tests {}\n",
            [Path.Combine(
                "tests",
                "RenderCheck",
                "RenderCheck.csproj")] = "<Project />\n",
            [Path.Combine(
                "tests",
                "RenderCheck",
                "Program.cs")] = "public static class RenderCheck {}\n",
            ["README.md"] = "not part of the image\n",
            ["Program.cs"] = "not part of the runtime image context\n",
        };
        WriteFiles(root, files);
        return root;
    }

    private static string MakePublishRoot()
    {
        var root = TemporaryPath();
        var files = new Dictionary<string, string>
        {
            [Path.Combine("app", "FlexContainerHtmlToPdf.dll")] = "app-binary",
            [Path.Combine("app", "FlexContainerHtmlToPdf.deps.json")] = "{}",
            [Path.Combine("rendercheck", "RenderCheck.dll")] = "render-binary",
            [Path.Combine("rendercheck", "RenderCheck.deps.json")] = "{}",
        };
        WriteFiles(root, files);
        return root;
    }

    private static string PrepareAndHash(
        string repository,
        string publish)
    {
        var destination = TemporaryPath();
        try
        {
            return DeploymentOperations.PrepareImageContext(
                repository,
                destination,
                publish);
        }
        finally
        {
            DeleteDirectory(destination);
        }
    }

    private static void WriteFiles(
        string root,
        IReadOnlyDictionary<string, string> files)
    {
        foreach (var (relative, content) in files)
        {
            var path = Path.Combine(root, relative);
            Directory.CreateDirectory(
                Path.GetDirectoryName(path) ??
                    throw new InvalidOperationException());
            File.WriteAllText(path, content, new UTF8Encoding(false));
        }
    }

    private static string TemporaryPath() =>
        Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));

    private static Dictionary<string, string> ParameterEnvironment() =>
        new(StringComparer.Ordinal)
        {
            ["AZURE_ENV_NAME"] = "sample",
            ["AZURE_FUNCTION_NAME"] = "func-sample",
            ["AZURE_FUNCTION_LOCATION"] = "eastus2euap",
            ["AZURE_APP_SERVICE_PLAN_ID"] = "/plans/sample",
            ["AZURE_APPLICATION_INSIGHTS_CONNECTION_STRING"] =
                "test-application-insights-value",
            ["AZURE_STORAGE_ACCOUNT_NAME"] = "stsample",
            ["AZURE_USER_ASSIGNED_IDENTITY_ID"] = "/identities/sample",
            ["AZURE_USER_ASSIGNED_IDENTITY_CLIENT_ID"] = "client-id",
            ["AZURE_FUNCTION_SUBNET_ID"] = "/subnets/sample",
            ["REGISTRY_IMAGE"] =
                "registry.example/repository:tag@sha256:digest",
            ["AZURE_ACR_TOKEN_NAME"] = "pull-token",
            ["REGISTRY_PASSWORD"] = "password",
        };

    private static void DeleteDirectory(string path)
    {
        if (Directory.Exists(path))
        {
            Directory.Delete(path, true);
        }
    }

    private sealed class EnvironmentScope : IDisposable
    {
        private readonly Dictionary<string, string?> original = [];

        public EnvironmentScope(IReadOnlyDictionary<string, string> values)
        {
            foreach (var (name, value) in values)
            {
                original[name] = Environment.GetEnvironmentVariable(name);
                Environment.SetEnvironmentVariable(name, value);
            }
        }

        public void Dispose()
        {
            foreach (var (name, value) in original)
            {
                Environment.SetEnvironmentVariable(name, value);
            }
        }
    }
}
