using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace DeployHelper;

public static class DeploymentOperations
{
    internal static readonly string[] StaticContextInputs =
    [
        ".dockerignore",
        "dotnet10.Dockerfile",
    ];

    internal static readonly string[] StaticHashInputs =
    [
        ".dockerignore",
        "dotnet10.Dockerfile",
        "FlexContainerHtmlToPdf.csproj",
        "host.json",
        "NuGet.config",
        Path.Combine(
            "tests",
            "FlexContainerHtmlToPdf.Tests",
            "FlexContainerHtmlToPdf.Tests.csproj"),
        Path.Combine("tests", "RenderCheck", "Program.cs"),
        Path.Combine("tests", "RenderCheck", "RenderCheck.csproj"),
    ];

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
    };

    public static void Run(string[] arguments)
    {
        if (arguments.Length == 0)
        {
            throw UsageError();
        }

        switch (arguments[0])
        {
            case "stage-context" when arguments.Length == 3:
                Console.Write(PrepareImageContext(
                    Directory.GetCurrentDirectory(),
                    arguments[1],
                    arguments[2]));
                return;
            case "source-hash" when arguments.Length == 1:
                Console.Write(HashBuildInputs(Directory.GetCurrentDirectory()));
                return;
            case "write-parameters" when arguments.Length == 2:
                WriteParameters(arguments[1]);
                return;
            case "validate-pdf" when arguments.Length == 2:
                Console.Write($"Valid PDF: {ValidatePdf(arguments[1])} bytes");
                return;
            case "validate-site" when arguments.Length == 1:
                ValidateSite();
                return;
            case "trace-context" when arguments.Length == 1:
                var trace = CreateTraceContext();
                Console.WriteLine(trace.TraceId);
                Console.Write(trace.TraceParent);
                return;
            case "verification-json" when arguments.Length == 1:
                Console.Write(JsonSerializer.Serialize(
                    BuildVerificationResult(),
                    JsonOptions));
                return;
            default:
                throw UsageError();
        }
    }

    internal static string PrepareImageContext(
        string repositoryRoot,
        string destinationRoot,
        string publishRoot)
    {
        var repository = Path.GetFullPath(repositoryRoot);
        var destination = Path.GetFullPath(destinationRoot);
        var publish = Path.GetFullPath(publishRoot);
        Directory.CreateDirectory(destination);
        if (Directory.EnumerateFileSystemEntries(destination).Any())
        {
            throw new InvalidOperationException(
                $"Image-context destination must be empty: {destination}");
        }

        foreach (var input in ImageInputs(repository, publish))
        {
            CopyInput(input, destination);
        }

        return HashBuildInputs(repository);
    }

    internal static IReadOnlyList<ImageInput> ImageInputs(
        string repositoryRoot,
        string publishRoot)
    {
        var inputs = new List<ImageInput>(StaticContextInputs.Length + 64);
        foreach (var relativePath in StaticContextInputs)
        {
            var path = Path.Combine(repositoryRoot, relativePath);
            if (!File.Exists(path))
            {
                throw new FileNotFoundException(
                    $"Required image input is missing: {path}",
                    path);
            }
            inputs.Add(new ImageInput(path, relativePath));
        }

        foreach (var required in new[]
        {
            Path.Combine("app", "FlexContainerHtmlToPdf.dll"),
            Path.Combine("rendercheck", "RenderCheck.dll"),
        })
        {
            var path = Path.Combine(publishRoot, required);
            if (!File.Exists(path))
            {
                throw new FileNotFoundException(
                    $"Required published output is missing: {path}",
                    path);
            }
        }

        var publishedFiles = new List<string>();
        CollectPublishedFiles(publishRoot, publishedFiles);
        foreach (var path in publishedFiles.Order(StringComparer.Ordinal))
        {
            var relative = Path.GetRelativePath(publishRoot, path);
            inputs.Add(new ImageInput(
                path,
                Path.Combine("publish", relative)));
        }

        return inputs
            .OrderBy(input => input.DestinationRelativePath, StringComparer.Ordinal)
            .ToArray();
    }

    internal static string HashBuildInputs(string repositoryRoot)
    {
        var root = Path.GetFullPath(repositoryRoot);
        using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        AppendUtf8(digest, "flex-container-dotnet-image-context-v3\0");

        foreach (var input in BuildInputs(root))
        {
            RejectReparsePoint(input.SourcePath);
            var relative = input.DestinationRelativePath
                .Replace(Path.DirectorySeparatorChar, '/');
            var content = File.ReadAllBytes(input.SourcePath);
            AppendUtf8(
                digest,
                $"file\0{relative}\0{content.Length}\0");
            digest.AppendData(content);
            digest.AppendData([0]);
        }

        return Convert.ToHexString(digest.GetHashAndReset())
            .ToLowerInvariant();
    }

    internal static IReadOnlyList<ImageInput> BuildInputs(string repositoryRoot)
    {
        var inputs = new List<ImageInput>(StaticHashInputs.Length + 16);
        foreach (var relativePath in StaticHashInputs)
        {
            var path = Path.Combine(repositoryRoot, relativePath);
            if (!File.Exists(path))
            {
                throw new FileNotFoundException(
                    $"Required build input is missing: {path}",
                    path);
            }
            inputs.Add(new ImageInput(path, relativePath));
        }

        var rootSources = Directory
            .GetFiles(repositoryRoot, "*.cs", SearchOption.TopDirectoryOnly)
            .Order(StringComparer.Ordinal)
            .ToArray();
        if (rootSources.Length == 0)
        {
            throw new InvalidOperationException(
                $"No root-level C# source files were found in {repositoryRoot}");
        }
        inputs.AddRange(rootSources.Select(path => new ImageInput(
            path,
            Path.GetRelativePath(repositoryRoot, path))));

        var testRoot = Path.Combine(
            repositoryRoot,
            "tests",
            "FlexContainerHtmlToPdf.Tests");
        var testSources = Directory
            .GetFiles(testRoot, "*.cs", SearchOption.TopDirectoryOnly)
            .Order(StringComparer.Ordinal)
            .ToArray();
        if (testSources.Length == 0)
        {
            throw new InvalidOperationException(
                $"No test source files were found in {testRoot}");
        }
        inputs.AddRange(testSources.Select(path => new ImageInput(
            path,
            Path.GetRelativePath(repositoryRoot, path))));

        return inputs
            .OrderBy(input => input.DestinationRelativePath, StringComparer.Ordinal)
            .ToArray();
    }

    internal static void WriteParameters(string path)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["environmentName"] = "AZURE_ENV_NAME",
            ["functionAppName"] = "AZURE_FUNCTION_NAME",
            ["functionLocation"] = "AZURE_FUNCTION_LOCATION",
            ["appServicePlanId"] = "AZURE_APP_SERVICE_PLAN_ID",
            ["applicationInsightsConnectionString"] =
                "AZURE_APPLICATION_INSIGHTS_CONNECTION_STRING",
            ["storageAccountName"] = "AZURE_STORAGE_ACCOUNT_NAME",
            ["userAssignedIdentityId"] =
                "AZURE_USER_ASSIGNED_IDENTITY_ID",
            ["userAssignedIdentityClientId"] =
                "AZURE_USER_ASSIGNED_IDENTITY_CLIENT_ID",
            ["virtualNetworkSubnetId"] = "AZURE_FUNCTION_SUBNET_ID",
            ["registryImage"] = "REGISTRY_IMAGE",
            ["registryUsername"] = "AZURE_ACR_TOKEN_NAME",
            ["registryPassword"] = "REGISTRY_PASSWORD",
        };

        var parameters = values.ToDictionary(
            item => item.Key,
            item => new ParameterValue(
                RequiredEnvironmentValue(item.Value)),
            StringComparer.Ordinal);
        var parameterFile = new ParameterFile(
            "https://schema.management.azure.com/schemas/" +
                "2019-04-01/deploymentParameters.json#",
            "1.0.0.0",
            parameters);

        var content = JsonSerializer.Serialize(parameterFile, JsonOptions) +
            Environment.NewLine;
        File.WriteAllText(path, content, new UTF8Encoding(false));
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(
                path,
                UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
    }

    internal static int ValidatePdf(string path)
    {
        var content = File.ReadAllBytes(path);
        if (content.Length < 100 ||
            !content.AsSpan().StartsWith("%PDF-"u8) ||
            !TrimEnd(content).EndsWith("%%EOF"u8))
        {
            throw new InvalidOperationException($"Invalid PDF: {path}");
        }
        return content.Length;
    }

    internal static void ValidateSite()
    {
        var site = JsonSerializer.Deserialize<SiteState>(
            RequiredEnvironmentValue("SITE_JSON"),
            JsonOptions) ?? throw new InvalidOperationException(
                "Function App state is empty.");
        var webConfig = JsonSerializer.Deserialize<WebConfig>(
            RequiredEnvironmentValue("WEB_CONFIG_JSON"),
            JsonOptions) ?? throw new InvalidOperationException(
                "Function App web configuration is empty.");
        var ftpPolicy = JsonSerializer.Deserialize<PublishingPolicy>(
            RequiredEnvironmentValue("FTP_POLICY_JSON"),
            JsonOptions) ?? throw new InvalidOperationException(
                "FTP publishing policy is empty.");
        var scmPolicy = JsonSerializer.Deserialize<PublishingPolicy>(
            RequiredEnvironmentValue("SCM_POLICY_JSON"),
            JsonOptions) ?? throw new InvalidOperationException(
                "SCM publishing policy is empty.");

        var expectedImage =
            RequiredEnvironmentValue("AZURE_REGISTRY_IMAGE");
        var expectedSubnet =
            RequiredEnvironmentValue("AZURE_FUNCTION_SUBNET_ID");
        var expectedIdentity =
            RequiredEnvironmentValue("AZURE_USER_ASSIGNED_IDENTITY_ID");

        if (site.State != "Running" ||
            site.Type != "Registry" ||
            site.Value != expectedImage ||
            site.Subnet != expectedSubnet ||
            !site.HttpsOnly ||
            webConfig.MinTlsVersion != "1.2" ||
            webConfig.ScmMinTlsVersion != "1.2" ||
            webConfig.FtpsState != "Disabled" ||
            !webConfig.Http20Enabled ||
            webConfig.RemoteDebuggingEnabled ||
            !site.IdentityType.Contains(
                "UserAssigned",
                StringComparison.Ordinal) ||
            !ContainsIdentity(site.IdentityIds, expectedIdentity) ||
            ftpPolicy.Properties.Allow ||
            scmPolicy.Properties.Allow)
        {
            throw new InvalidOperationException(
                "The Function App deployment, identity, network, TLS, or " +
                "publishing configuration does not match.");
        }
    }

    internal static TraceContext CreateTraceContext()
    {
        var traceId = RandomHex(16);
        var parentId = RandomHex(8);
        return new TraceContext(
            traceId,
            $"00-{traceId}-{parentId}-01");
    }

    internal static VerificationResult BuildVerificationResult()
    {
        return new VerificationResult(
            RequiredEnvironmentValue("AZURE_FUNCTION_NAME"),
            "Running",
            "Registry",
            RequiredEnvironmentValue("AZURE_REGISTRY_IMAGE"),
            RequiredEnvironmentValue("AZURE_IMAGE_CONTEXT_HASH"),
            RequiredEnvironmentValue("AZURE_IMAGE_BUILD_ACTION"),
            RequiredEnvironmentValue("AZURE_IMAGE_DIGEST"),
            Environment
                .GetEnvironmentVariable("LEAF_NAMES")?
                .Split(
                    (char[]?)null,
                    StringSplitOptions.RemoveEmptyEntries |
                        StringSplitOptions.TrimEntries) ?? [],
            RequiredEnvironmentInt("HELLO_GET_STATUS"),
            RequiredEnvironmentInt("HELLO_POST_STATUS"),
            RequiredEnvironmentInt("PDF_GET_BYTES"),
            RequiredEnvironmentInt("PDF_POST_BYTES"),
            RequiredEnvironmentInt("INVALID_STATUS"),
            RequiredEnvironmentInt("APPINSIGHTS_REQUEST_COUNT"),
            RequiredEnvironmentInt("APPINSIGHTS_FAILED_REQUEST_COUNT"),
            RequiredEnvironmentBool("STORAGE_ROLE_VERIFIED"),
            RequiredEnvironmentBool("MONITORING_ROLE_VERIFIED"),
            RequiredEnvironmentValue("VERIFIED_UTC"));
    }

    private static void CopyInput(
        ImageInput input,
        string destinationRoot)
    {
        RejectReparsePoint(input.SourcePath);
        var destination = Path.Combine(
            destinationRoot,
            input.DestinationRelativePath);
        Directory.CreateDirectory(
            Path.GetDirectoryName(destination) ??
                throw new InvalidOperationException(
                    $"Image input has no parent directory: {destination}"));
        File.Copy(input.SourcePath, destination, false);
    }

    private static void CollectPublishedFiles(
        string directory,
        ICollection<string> files)
    {
        RejectReparsePoint(directory);
        foreach (var path in Directory.EnumerateFileSystemEntries(directory))
        {
            RejectReparsePoint(path);
            if (Directory.Exists(path))
            {
                CollectPublishedFiles(path, files);
            }
            else if (File.Exists(path))
            {
                files.Add(path);
            }
            else
            {
                throw new InvalidOperationException(
                    $"Unsupported published output: {path}");
            }
        }
    }

    private static void RejectReparsePoint(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidOperationException(
                $"Symbolic links are not allowed: {path}");
        }
    }

    private static void AppendUtf8(
        IncrementalHash digest,
        string value) =>
        digest.AppendData(Encoding.UTF8.GetBytes(value));

    private static ReadOnlySpan<byte> TrimEnd(byte[] content)
    {
        var end = content.Length;
        while (end > 0 && char.IsWhiteSpace((char)content[end - 1]))
        {
            end--;
        }
        return content.AsSpan(0, end);
    }

    private static string RandomHex(int byteCount)
    {
        while (true)
        {
            var value = Convert.ToHexString(
                RandomNumberGenerator.GetBytes(byteCount))
                .ToLowerInvariant();
            if (value.Any(character => character != '0'))
            {
                return value;
            }
        }
    }

    private static bool ContainsIdentity(
        JsonElement identities,
        string expectedIdentity)
    {
        return identities.ValueKind switch
        {
            JsonValueKind.String => string.Equals(
                identities.GetString(),
                expectedIdentity,
                StringComparison.OrdinalIgnoreCase),
            JsonValueKind.Array => identities
                .EnumerateArray()
                .Any(item =>
                    item.ValueKind == JsonValueKind.String &&
                    string.Equals(
                        item.GetString(),
                        expectedIdentity,
                        StringComparison.OrdinalIgnoreCase)),
            _ => false,
        };
    }

    private static string RequiredEnvironmentValue(string name)
    {
        var value = Environment.GetEnvironmentVariable(name);
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new InvalidOperationException(
                $"Required environment value '{name}' is missing.");
        }
        return value;
    }

    private static int RequiredEnvironmentInt(string name)
    {
        var value = RequiredEnvironmentValue(name);
        return int.TryParse(value, out var number)
            ? number
            : throw new InvalidOperationException(
                $"Environment value '{name}' must be an integer.");
    }

    private static bool RequiredEnvironmentBool(string name)
    {
        var value = RequiredEnvironmentValue(name);
        return bool.TryParse(value, out var result)
            ? result
            : throw new InvalidOperationException(
                $"Environment value '{name}' must be true or false.");
    }

    private static Exception UsageError() =>
        new InvalidOperationException(
            "usage: DeployHelper " +
            "<source-hash|stage-context|write-parameters|validate-pdf|" +
            "validate-site|trace-context|verification-json> " +
            "[destination] [publish-root]");
}

public sealed record ImageInput(
    string SourcePath,
    string DestinationRelativePath);

public sealed record ParameterValue(
    [property: JsonPropertyName("value")] string Value);

public sealed record ParameterFile(
    [property: JsonPropertyName("$schema")] string Schema,
    string ContentVersion,
    IReadOnlyDictionary<string, ParameterValue> Parameters);

public sealed record SiteState(
    string State,
    string Type,
    string Value,
    string Subnet,
    string IdentityType,
    JsonElement IdentityIds,
    bool HttpsOnly);

public sealed record WebConfig(
    string MinTlsVersion,
    string ScmMinTlsVersion,
    string FtpsState,
    bool Http20Enabled,
    bool RemoteDebuggingEnabled);

public sealed record PublishingPolicy(PublishingPolicyProperties Properties);

public sealed record PublishingPolicyProperties(bool Allow);

public sealed record TraceContext(string TraceId, string TraceParent);

public sealed record VerificationResult(
    string FunctionApp,
    string State,
    string DeploymentType,
    string Image,
    string ImageContextHash,
    string ImageBuildAction,
    string ImageDigest,
    string[] Functions,
    int HelloGetStatus,
    int HelloPostStatus,
    int PdfGetBytes,
    int PdfPostBytes,
    int InvalidContentTypeStatus,
    int ApplicationInsightsRequestCount,
    int ApplicationInsightsFailedRequestCount,
    bool StorageRoleVerified,
    bool MonitoringRoleVerified,
    string VerifiedUtc);
