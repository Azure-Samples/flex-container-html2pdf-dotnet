$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $repositoryRoot

function Get-AzdValue {
    param([Parameter(Mandatory)][string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = (& azd env get-value $Name).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Required azd environment value '$Name' is missing."
    }
    return $value
}

function Get-DotnetCommand {
    $command = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $command) {
        throw '.NET 10 SDK or later is required for the deployment helper.'
    }
    $versions = @(& $command.Source --list-sdks)
    if (-not ($versions | Where-Object { $_ -match '^(1[0-9]|[2-9][0-9])\.' })) {
        throw '.NET 10 SDK or later is required for the deployment helper.'
    }
    return $command.Source
}

function Publish-DeployHelper {
    param(
        [Parameter(Mandatory)][string]$Dotnet,
        [Parameter(Mandatory)][string]$OutputPath
    )

    & $Dotnet publish `
        .\infra\scripts\DeployHelper\DeployHelper.csproj `
        --configuration Release `
        --output $OutputPath `
        --nologo `
        -p:NuGetAudit=false |
        Out-Null
    $helper = Join-Path $OutputPath 'DeployHelper.dll'
    if (-not (Test-Path -LiteralPath $helper)) {
        throw "Deployment helper was not published: $helper"
    }
    return $helper
}

function New-TraceContext {
    $values = @(& $dotnet $helper trace-context)
    if ($values.Count -ne 2 -or
        $values[0] -notmatch '^[0-9a-f]{32}$' -or
        $values[1] -notmatch '^00-[0-9a-f]{32}-[0-9a-f]{16}-01$') {
        throw 'Deployment helper returned an invalid trace context.'
    }
    return [pscustomobject]@{
        TraceId = $values[0]
        TraceParent = $values[1]
    }
}

function Invoke-CurlRequest {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Directory
    )

    $trace = New-TraceContext
    $headersPath = Join-Path $Directory "$Name.headers"
    $bodyPath = Join-Path $Directory "$Name.body"
    $curlArguments = @(
        '--silent',
        '--show-error',
        '--max-time', '120',
        '--header', "traceparent: $($trace.TraceParent)",
        '--dump-header', $headersPath,
        '--output', $bodyPath,
        '--write-out', '%{http_code}'
    ) + $Arguments
    $statusText = & curl.exe @curlArguments
    $exitCode = $LASTEXITCODE
    $status = if ($statusText -match '^\d{3}$') {
        [int]$statusText
    } else {
        0
    }
    return [pscustomobject]@{
        Name = $Name
        ExitCode = $exitCode
        Status = $status
        TraceId = $trace.TraceId
        HeadersPath = $headersPath
        BodyPath = $bodyPath
    }
}

function Get-ResponseContentType {
    param([Parameter(Mandatory)][string]$HeadersPath)

    $line = Select-String `
        -Path $HeadersPath `
        -Pattern '^Content-Type:' `
        -CaseSensitive:$false |
        Select-Object -Last 1
    if (-not $line) {
        return ''
    }
    return ($line.Line -split ':', 2)[1].Trim()
}

function Wait-ForWorker {
    param(
        [Parameter(Mandatory)][string]$SiteId,
        [Parameter(Mandatory)][string]$HostName
    )

    $deadline = [DateTime]::UtcNow.AddMinutes(6)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $functionNames = @(
                & az rest `
                    --method get `
                    --url "https://management.azure.com$SiteId/functions?api-version=2026-08-01" `
                    --query 'value[].name' `
                    --output tsv
            )
            $leafNames = @(
                $functionNames |
                    ForEach-Object { ($_ -split '/')[-1] } |
                    Where-Object { $_ }
            )
            if ($leafNames.Count -eq 2 -and
                $leafNames -contains 'Hello' -and
                $leafNames -contains 'HtmlToPdf') {
                $keys = & az functionapp keys list `
                    --resource-group $resourceGroup `
                    --name $functionAppName `
                    --output json |
                    ConvertFrom-Json
                $masterKey = [string]$keys.masterKey
                if (-not [string]::IsNullOrWhiteSpace($masterKey)) {
                    $status = & curl.exe `
                        --silent `
                        --show-error `
                        --max-time 30 `
                        --header "x-functions-key: $masterKey" `
                        --output (
                            Join-Path $temporaryDirectory 'host-status.body'
                        ) `
                        --write-out '%{http_code}' `
                        "https://$HostName/admin/host/status"
                    $masterKey = $null
                    $keys = $null
                    if ($status -eq '200') {
                        return $leafNames
                    }
                }
            }
        } catch {
            Write-Verbose "Worker readiness probe failed: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds 10
    }
    throw 'The worker did not become ready within six minutes.'
}

$temporaryDirectory = $null
$helperDirectory = $null

try {
    $dotnet = Get-DotnetCommand
    $subscriptionId = Get-AzdValue 'AZURE_SUBSCRIPTION_ID'
    $environmentName = Get-AzdValue 'AZURE_ENV_NAME'
    $resourceGroup = Get-AzdValue 'AZURE_RESOURCE_GROUP'
    $functionAppName = Get-AzdValue 'AZURE_FUNCTION_NAME'
    $apiUrl = (Get-AzdValue 'API_URL').TrimEnd('/')
    $registryImage = Get-AzdValue 'AZURE_REGISTRY_IMAGE'
    $functionSubnetId = Get-AzdValue 'AZURE_FUNCTION_SUBNET_ID'
    $identityId = Get-AzdValue 'AZURE_USER_ASSIGNED_IDENTITY_ID'
    $identityPrincipalId =
        Get-AzdValue 'AZURE_USER_ASSIGNED_IDENTITY_PRINCIPAL_ID'
    $storageAccountId = Get-AzdValue 'AZURE_STORAGE_ACCOUNT_ID'
    $applicationInsightsId = Get-AzdValue 'AZURE_APPLICATION_INSIGHTS_ID'
    $applicationInsightsName =
        Get-AzdValue 'AZURE_APPLICATION_INSIGHTS_NAME'
    $contextHash = Get-AzdValue 'AZURE_IMAGE_CONTEXT_HASH'
    $buildAction = Get-AzdValue 'AZURE_IMAGE_BUILD_ACTION'
    $imageDigest = Get-AzdValue 'AZURE_IMAGE_DIGEST'
    $siteId = (
        "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/" +
        "providers/Microsoft.Web/sites/$functionAppName"
    )

    & az account set --subscription $subscriptionId

    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) (
        "dotnet-pdf-verification-$([guid]::NewGuid().ToString('N'))"
    )
    $helperDirectory = Join-Path ([IO.Path]::GetTempPath()) (
        "dotnet-deploy-helper-$([guid]::NewGuid().ToString('N'))"
    )
    New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
    New-Item -ItemType Directory -Path $helperDirectory | Out-Null
    $helper = Publish-DeployHelper `
        -Dotnet $dotnet `
        -OutputPath $helperDirectory

    $site = & az rest `
        --method get `
        --url "https://management.azure.com$siteId`?api-version=2026-08-01" `
        --output json |
        ConvertFrom-Json
    $leafNames = Wait-ForWorker `
        -SiteId $siteId `
        -HostName $site.properties.defaultHostName
    $verificationStart = [DateTime]::UtcNow.ToString('o')

    $helloGet = Invoke-CurlRequest `
        -Name 'hello-get' `
        -Arguments @("$apiUrl/api/hello") `
        -Directory $temporaryDirectory
    $helloGetBody = Get-Content -LiteralPath $helloGet.BodyPath -Raw
    if ($helloGet.ExitCode -ne 0 -or
        $helloGet.Status -ne 200 -or
        $helloGetBody -cne 'Hello from the .NET worker.') {
        throw 'Hello GET did not return the exact expected response.'
    }

    $helloPost = Invoke-CurlRequest `
        -Name 'hello-post' `
        -Arguments @('--request', 'POST', "$apiUrl/api/hello") `
        -Directory $temporaryDirectory
    $helloPostBody = Get-Content -LiteralPath $helloPost.BodyPath -Raw
    if ($helloPost.ExitCode -ne 0 -or
        $helloPost.Status -ne 200 -or
        $helloPostBody -cne 'Hello from the .NET worker.') {
        throw 'Hello POST did not return the exact expected response.'
    }

    $pdfGet = Invoke-CurlRequest `
        -Name 'pdf-get' `
        -Arguments @("$apiUrl/api/html-to-pdf") `
        -Directory $temporaryDirectory
    $pdfGetContentType = Get-ResponseContentType $pdfGet.HeadersPath
    $pdfGetBytes = [int](
        & $dotnet $helper validate-pdf $pdfGet.BodyPath |
            Select-String -Pattern '\d+' |
            ForEach-Object { $_.Matches[0].Value }
    )
    if ($pdfGet.ExitCode -ne 0 -or
        $pdfGet.Status -ne 200 -or
        $pdfGetContentType -notmatch '^application/pdf') {
        throw 'HTML-to-PDF GET did not return a valid PDF response.'
    }

    $pdfPost = Invoke-CurlRequest `
        -Name 'pdf-post' `
        -Arguments @(
            '--request', 'POST',
            '--header', 'Content-Type: text/html; charset=utf-8',
            '--data-binary', '@sample.html',
            "$apiUrl/api/html-to-pdf"
        ) `
        -Directory $temporaryDirectory
    $pdfPostContentType = Get-ResponseContentType $pdfPost.HeadersPath
    $pdfPostBytes = [int](
        & $dotnet $helper validate-pdf $pdfPost.BodyPath |
            Select-String -Pattern '\d+' |
            ForEach-Object { $_.Matches[0].Value }
    )
    if ($pdfPost.ExitCode -ne 0 -or
        $pdfPost.Status -ne 200 -or
        $pdfPostContentType -notmatch '^application/pdf') {
        throw 'HTML-to-PDF POST did not return a valid PDF response.'
    }

    $invalidPost = Invoke-CurlRequest `
        -Name 'pdf-invalid-json' `
        -Arguments @(
            '--request', 'POST',
            '--header', 'Content-Type: application/json',
            '--data-binary', '{}',
            "$apiUrl/api/html-to-pdf"
        ) `
        -Directory $temporaryDirectory
    $invalidBody = Get-Content -LiteralPath $invalidPost.BodyPath -Raw |
        ConvertFrom-Json
    if ($invalidPost.ExitCode -ne 0 -or
        $invalidPost.Status -ne 415 -or
        $invalidBody.error -cne 'unsupported_media_type') {
        throw 'The endpoint did not reject application/json with HTTP 415.'
    }

    $site = & az rest `
        --method get `
        --url "https://management.azure.com$siteId`?api-version=2026-08-01" `
        --output json |
        ConvertFrom-Json
    $identityIds = if ($site.identity.userAssignedIdentities) {
        @($site.identity.userAssignedIdentities.PSObject.Properties.Name)
    } else {
        @()
    }
    $siteState = [ordered]@{
        state = $site.properties.state
        type = $site.properties.functionAppConfig.deployment.storage.type
        value = $site.properties.functionAppConfig.deployment.storage.value
        subnet = $site.properties.virtualNetworkSubnetId
        identityType = $site.identity.type
        identityIds = $identityIds
        httpsOnly = $site.properties.httpsOnly
    } | ConvertTo-Json -Depth 6 -Compress
    $webConfig = & az rest `
        --method get `
        --url (
            "https://management.azure.com$siteId/" +
            "config/web?api-version=2022-03-01"
        ) `
        --query (
            '{minTlsVersion:properties.minTlsVersion,' +
            'scmMinTlsVersion:properties.scmMinTlsVersion,' +
            'ftpsState:properties.ftpsState,' +
            'http20Enabled:properties.http20Enabled,' +
            'remoteDebuggingEnabled:properties.remoteDebuggingEnabled}'
        ) `
        --output json
    $ftpPolicy = & az rest `
        --method get `
        --url (
            "https://management.azure.com$siteId/" +
            "basicPublishingCredentialsPolicies/ftp?api-version=2022-03-01"
        ) `
        --output json
    $scmPolicy = & az rest `
        --method get `
        --url (
            "https://management.azure.com$siteId/" +
            "basicPublishingCredentialsPolicies/scm?api-version=2022-03-01"
        ) `
        --output json
    [Environment]::SetEnvironmentVariable('SITE_JSON', $siteState)
    [Environment]::SetEnvironmentVariable('WEB_CONFIG_JSON', $webConfig)
    [Environment]::SetEnvironmentVariable('FTP_POLICY_JSON', $ftpPolicy)
    [Environment]::SetEnvironmentVariable('SCM_POLICY_JSON', $scmPolicy)
    [Environment]::SetEnvironmentVariable(
        'AZURE_REGISTRY_IMAGE',
        $registryImage)
    [Environment]::SetEnvironmentVariable(
        'AZURE_FUNCTION_SUBNET_ID',
        $functionSubnetId)
    [Environment]::SetEnvironmentVariable(
        'AZURE_USER_ASSIGNED_IDENTITY_ID',
        $identityId)
    & $dotnet $helper validate-site

    $appSettings = & az rest `
        --method post `
        --url (
            "https://management.azure.com$siteId/" +
            "config/appsettings/list?api-version=2026-08-01"
        ) `
        --output json |
        ConvertFrom-Json
    $settingNames = @($appSettings.properties.PSObject.Properties.Name)
    $appSettings = $null
    foreach ($forbiddenName in @(
            'FUNCTIONS_APPLICATION_DIRECTORY',
            'AzureWebJobsScriptRoot',
            'WEBSITE_RUN_FROM_PACKAGE'
        )) {
        if ($settingNames -contains $forbiddenName) {
            throw "Forbidden application setting '$forbiddenName' is present."
        }
    }

    $storageRole = (& az role assignment list `
            --assignee-object-id $identityPrincipalId `
            --scope $storageAccountId `
            --query (
                "[?roleDefinitionName=='Storage Blob Data Owner']." +
                "roleDefinitionName | [0]"
            ) `
            --output tsv).Trim()
    $monitoringRole = (& az role assignment list `
            --assignee-object-id $identityPrincipalId `
            --scope $applicationInsightsId `
            --query (
                "[?roleDefinitionName=='Monitoring Metrics Publisher']." +
                "roleDefinitionName | [0]"
            ) `
            --output tsv).Trim()
    if ($storageRole -ne 'Storage Blob Data Owner' -or
        $monitoringRole -ne 'Monitoring Metrics Publisher') {
        throw 'The managed-identity role assignments do not match.'
    }

    $traceIds = @(
        $helloGet.TraceId,
        $helloPost.TraceId,
        $pdfGet.TraceId,
        $pdfPost.TraceId,
        $invalidPost.TraceId
    )
    $traceList = ($traceIds | ForEach-Object { "'$_'" }) -join ','
    $appId = (& az monitor app-insights component show `
            --resource-group $resourceGroup `
            --app $applicationInsightsName `
            --query appId `
            --output tsv).Trim()
    $requestRows = @()
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $query = (
            "requests | where timestamp >= datetime($verificationStart) " +
            "| where operation_Id in ($traceList) " +
            "| project operation_Id, success, resultCode"
        )
        $telemetry = & az monitor app-insights query `
            --app $appId `
            --analytics-query $query `
            --output json |
            ConvertFrom-Json
        $requestRows = @($telemetry.tables[0].rows)
        if ($requestRows.Count -ge $traceIds.Count) {
            break
        }
        Start-Sleep -Seconds 15
    }
    $observedTraceIds = @(
        $requestRows |
            ForEach-Object { [string]$_[0] } |
            Sort-Object -Unique
    )
    $missingTraceIds = @(
        $traceIds | Where-Object { $_ -notin $observedTraceIds }
    )
    $failedRequests = @(
        $requestRows | Where-Object { $_[1] -ne $true }
    )
    if ($requestRows.Count -ne $traceIds.Count -or
        $missingTraceIds.Count -ne 0 -or
        $failedRequests.Count -ne 0) {
        throw (
            "Application Insights verification failed: " +
            "requests=$($requestRows.Count), " +
            "missing=$($missingTraceIds.Count), " +
            "failed=$($failedRequests.Count)."
        )
    }

    $verifiedUtc = [DateTime]::UtcNow.ToString('o')
    & azd env set AZURE_VERIFIED_UTC $verifiedUtc --no-prompt | Out-Null

    $verificationEnvironment = @{
        AZURE_FUNCTION_NAME = $functionAppName
        AZURE_REGISTRY_IMAGE = $registryImage
        AZURE_IMAGE_CONTEXT_HASH = $contextHash
        AZURE_IMAGE_BUILD_ACTION = $buildAction
        AZURE_IMAGE_DIGEST = $imageDigest
        LEAF_NAMES = ($leafNames -join [Environment]::NewLine)
        HELLO_GET_STATUS = [string]$helloGet.Status
        HELLO_POST_STATUS = [string]$helloPost.Status
        PDF_GET_BYTES = [string]$pdfGetBytes
        PDF_POST_BYTES = [string]$pdfPostBytes
        INVALID_STATUS = [string]$invalidPost.Status
        APPINSIGHTS_REQUEST_COUNT = [string]$requestRows.Count
        APPINSIGHTS_FAILED_REQUEST_COUNT = [string]$failedRequests.Count
        STORAGE_ROLE_VERIFIED = 'true'
        MONITORING_ROLE_VERIFIED = 'true'
        VERIFIED_UTC = $verifiedUtc
    }
    foreach ($entry in $verificationEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
    }
    $verificationJson = & $dotnet $helper verification-json
    $verificationDirectory = Join-Path '.azure' $environmentName
    New-Item -ItemType Directory -Path $verificationDirectory -Force |
        Out-Null
    $verificationPath = Join-Path $verificationDirectory 'verification.json'
    $verificationJson |
        Set-Content -LiteralPath $verificationPath -Encoding utf8NoBOM
    Write-Output $verificationJson
    Write-Host "Verification evidence: $verificationPath"
} finally {
    foreach ($name in @(
            'SITE_JSON',
            'WEB_CONFIG_JSON',
            'FTP_POLICY_JSON',
            'SCM_POLICY_JSON',
            'AZURE_REGISTRY_IMAGE',
            'AZURE_FUNCTION_SUBNET_ID',
            'AZURE_USER_ASSIGNED_IDENTITY_ID',
            'AZURE_FUNCTION_NAME',
            'AZURE_IMAGE_CONTEXT_HASH',
            'AZURE_IMAGE_BUILD_ACTION',
            'AZURE_IMAGE_DIGEST',
            'LEAF_NAMES',
            'HELLO_GET_STATUS',
            'HELLO_POST_STATUS',
            'PDF_GET_BYTES',
            'PDF_POST_BYTES',
            'INVALID_STATUS',
            'APPINSIGHTS_REQUEST_COUNT',
            'APPINSIGHTS_FAILED_REQUEST_COUNT',
            'STORAGE_ROLE_VERIFIED',
            'MONITORING_ROLE_VERIFIED',
            'VERIFIED_UTC'
        )) {
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    if ($temporaryDirectory -and
        (Test-Path -LiteralPath $temporaryDirectory)) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
    if ($helperDirectory -and (Test-Path -LiteralPath $helperDirectory)) {
        Remove-Item -LiteralPath $helperDirectory -Recurse -Force
    }
    Pop-Location
}
