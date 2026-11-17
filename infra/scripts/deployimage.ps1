[CmdletBinding()]
param(
    [switch]$Verify
)

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

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$Operation,
        [int]$Attempts = 6,
        [int]$DelaySeconds = 10
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            return & $Operation
        } catch {
            if ($attempt -eq $Attempts) {
                throw
            }
            Start-Sleep -Seconds $DelaySeconds
        }
    }
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

$parameterPath = $null
$buildContext = $null
$publishRoot = $null
$helperDirectory = $null
$registryPassword = $null

try {
    $dotnet = Get-DotnetCommand
    $subscriptionId = Get-AzdValue 'AZURE_SUBSCRIPTION_ID'
    $environmentName = Get-AzdValue 'AZURE_ENV_NAME'
    $resourceGroup = Get-AzdValue 'AZURE_RESOURCE_GROUP'
    $registryName = Get-AzdValue 'AZURE_CONTAINER_REGISTRY_NAME'
    $registryEndpoint = Get-AzdValue 'AZURE_CONTAINER_REGISTRY_ENDPOINT'
    $imageRepository = Get-AzdValue 'AZURE_IMAGE_REPOSITORY'
    $tokenName = Get-AzdValue 'AZURE_ACR_TOKEN_NAME'
    $functionAppName = Get-AzdValue 'AZURE_FUNCTION_NAME'
    $functionLocation = Get-AzdValue 'AZURE_FUNCTION_LOCATION'
    $appServicePlanId = Get-AzdValue 'AZURE_APP_SERVICE_PLAN_ID'
    $storageAccountName = Get-AzdValue 'AZURE_STORAGE_ACCOUNT_NAME'
    $applicationInsightsConnectionString =
        Get-AzdValue 'AZURE_APPLICATION_INSIGHTS_CONNECTION_STRING'
    $identityId = Get-AzdValue 'AZURE_USER_ASSIGNED_IDENTITY_ID'
    $identityClientId = Get-AzdValue 'AZURE_USER_ASSIGNED_IDENTITY_CLIENT_ID'
    $functionSubnetId = Get-AzdValue 'AZURE_FUNCTION_SUBNET_ID'

    & az account set --subscription $subscriptionId

    $buildContext = Join-Path ([IO.Path]::GetTempPath()) (
        "function-image-$([guid]::NewGuid().ToString('N'))"
    )
    $publishRoot = Join-Path ([IO.Path]::GetTempPath()) (
        "function-publish-$([guid]::NewGuid().ToString('N'))"
    )
    $helperDirectory = Join-Path ([IO.Path]::GetTempPath()) (
        "dotnet-deploy-helper-$([guid]::NewGuid().ToString('N'))"
    )
    New-Item -ItemType Directory -Path $buildContext | Out-Null
    New-Item -ItemType Directory -Path $publishRoot | Out-Null
    New-Item -ItemType Directory -Path $helperDirectory | Out-Null
    $helper = Publish-DeployHelper `
        -Dotnet $dotnet `
        -OutputPath $helperDirectory

    & $dotnet restore `
        .\tests\FlexContainerHtmlToPdf.Tests\FlexContainerHtmlToPdf.Tests.csproj `
        -p:NuGetAudit=false `
        --nologo
    & $dotnet test `
        .\tests\FlexContainerHtmlToPdf.Tests\FlexContainerHtmlToPdf.Tests.csproj `
        --configuration Release `
        --no-restore `
        --nologo `
        -p:TreatWarningsAsErrors=true `
        -p:NuGetAudit=false
    & $dotnet restore `
        .\FlexContainerHtmlToPdf.csproj `
        --runtime linux-musl-x64 `
        -p:PublishReadyToRun=true `
        -p:NuGetAudit=false `
        --nologo
    & $dotnet publish `
        .\FlexContainerHtmlToPdf.csproj `
        --configuration Release `
        --runtime linux-musl-x64 `
        --self-contained false `
        --no-restore `
        --output (Join-Path $publishRoot 'app') `
        --nologo `
        -p:TreatWarningsAsErrors=true `
        -p:PublishReadyToRun=true `
        -p:DebugType=None `
        -p:DebugSymbols=false `
        -p:NuGetAudit=false
    Remove-Item `
        -LiteralPath (Join-Path $publishRoot 'app\worker.config.json') `
        -Force `
        -ErrorAction SilentlyContinue
    Remove-Item `
        -LiteralPath (Join-Path $publishRoot 'app\functions.metadata') `
        -Force `
        -ErrorAction SilentlyContinue

    & $dotnet restore `
        .\tests\RenderCheck\RenderCheck.csproj `
        --runtime linux-musl-x64 `
        -p:NuGetAudit=false `
        --nologo
    & $dotnet publish `
        .\tests\RenderCheck\RenderCheck.csproj `
        --configuration Release `
        --runtime linux-musl-x64 `
        --self-contained false `
        --no-restore `
        --output (Join-Path $publishRoot 'rendercheck') `
        --nologo `
        -p:TreatWarningsAsErrors=true `
        -p:DebugType=None `
        -p:DebugSymbols=false `
        -p:NuGetAudit=false

    $contextHash = (
        & $dotnet $helper stage-context $buildContext $publishRoot
    ).Trim()
    if ($contextHash -notmatch '^[0-9a-f]{64}$') {
        throw "Image-context hash is invalid: '$contextHash'."
    }

    $imageTag = "azd-$contextHash"
    $taggedImage = "$imageRepository`:$imageTag"

    $repositories = @(
        & az acr repository list `
            --name $registryName `
            --output tsv `
            --only-show-errors
    )
    $tagExists = $false
    if ($repositories -contains $imageRepository) {
        $tags = @(
            & az acr repository show-tags `
                --name $registryName `
                --repository $imageRepository `
                --output tsv `
                --only-show-errors
        )
        $tagExists = $tags -contains $imageTag
    }

    if ($tagExists) {
        $buildAction = 'reused'
        Write-Host (
            "Image context is unchanged; reusing " +
            "$registryEndpoint/$taggedImage"
        )
    } else {
        $buildAction = 'built'
        Write-Host (
            "Building Linux AMD64 image with ACR Tasks: " +
            "$registryEndpoint/$taggedImage"
        )
        $buildRunJson = & az acr build `
            --registry $registryName `
            --resource-group $resourceGroup `
            --platform linux/amd64 `
            --file dotnet10.Dockerfile `
            --image $taggedImage `
            --timeout 1800 `
            --no-logs `
            --only-show-errors `
            --output json `
            $buildContext
        $buildRun = $buildRunJson | ConvertFrom-Json
        if ($buildRun.status -ne 'Succeeded') {
            throw (
                "ACR build '$($buildRun.runId)' ended in state " +
                "'$($buildRun.status)'."
            )
        }
        Write-Host "ACR build '$($buildRun.runId)' succeeded."
    }

    $digest = Invoke-WithRetry {
        $value = (& az acr manifest show-metadata `
                --registry $registryName `
                --name $taggedImage `
                --query digest `
                --output tsv `
                --only-show-errors).Trim()
        if ($value -notmatch '^sha256:[0-9a-f]{64}$') {
            throw 'Image digest is not available yet.'
        }
        return $value
    }
    $registryImage = "$registryEndpoint/$taggedImage@$digest"

    & az acr repository update `
        --name $registryName `
        --image $taggedImage `
        --write-enabled false `
        --delete-enabled false `
        --only-show-errors |
        Out-Null

    $registryPassword = Invoke-WithRetry {
        $value = (& az acr token credential generate `
                --registry $registryName `
                --resource-group $resourceGroup `
                --name $tokenName `
                --password1 `
                --expiration-in-days 30 `
                --query "passwords[?name=='password1'].value | [0]" `
                --output tsv `
                --only-show-errors).Trim()
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw 'ACR token password generation returned no value.'
        }
        return $value
    }

    $parameterPath = Join-Path ([IO.Path]::GetTempPath()) (
        "function-app-$([guid]::NewGuid().ToString('N')).parameters.json"
    )
    $parameterEnvironment = @{
        AZURE_ENV_NAME = $environmentName
        AZURE_FUNCTION_NAME = $functionAppName
        AZURE_FUNCTION_LOCATION = $functionLocation
        AZURE_APP_SERVICE_PLAN_ID = $appServicePlanId
        AZURE_APPLICATION_INSIGHTS_CONNECTION_STRING =
            $applicationInsightsConnectionString
        AZURE_STORAGE_ACCOUNT_NAME = $storageAccountName
        AZURE_USER_ASSIGNED_IDENTITY_ID = $identityId
        AZURE_USER_ASSIGNED_IDENTITY_CLIENT_ID = $identityClientId
        AZURE_FUNCTION_SUBNET_ID = $functionSubnetId
        REGISTRY_IMAGE = $registryImage
        AZURE_ACR_TOKEN_NAME = $tokenName
        REGISTRY_PASSWORD = $registryPassword
    }
    foreach ($entry in $parameterEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
    }
    & $dotnet $helper write-parameters $parameterPath

    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
    $deploymentName = "registry-app-$timestamp"
    $state = (& az deployment group create `
            --resource-group $resourceGroup `
            --name $deploymentName `
            --template-file .\infra\app\api.bicep `
            --parameters "@$parameterPath" `
            --query properties.provisioningState `
            --output tsv `
            --only-show-errors).Trim()
    if ($state -ne 'Succeeded') {
        throw "Registry Function App deployment ended in state '$state'."
    }

    & azd env set AZURE_IMAGE_CONTEXT_HASH $contextHash --no-prompt |
        Out-Null
    & azd env set AZURE_IMAGE_BUILD_ACTION $buildAction --no-prompt |
        Out-Null
    & azd env set AZURE_IMAGE_TAG $imageTag --no-prompt | Out-Null
    & azd env set AZURE_IMAGE_DIGEST $digest --no-prompt | Out-Null
    & azd env set AZURE_REGISTRY_IMAGE $registryImage --no-prompt |
        Out-Null
    & azd env set API_URL "https://$functionAppName.azurewebsites.net" `
        --no-prompt |
        Out-Null

    & az functionapp start `
        --resource-group $resourceGroup `
        --name $functionAppName `
        --only-show-errors

    Write-Host "Updated Registry-backed Function App '$functionAppName'."
    Write-Host "Image action: $buildAction"
    Write-Host "Pinned image: $registryImage"

    if ($Verify) {
        & (Join-Path $PSScriptRoot 'postdeploy.ps1')
    }
} finally {
    foreach ($name in @(
            'AZURE_ENV_NAME',
            'AZURE_FUNCTION_NAME',
            'AZURE_FUNCTION_LOCATION',
            'AZURE_APP_SERVICE_PLAN_ID',
            'AZURE_APPLICATION_INSIGHTS_CONNECTION_STRING',
            'AZURE_STORAGE_ACCOUNT_NAME',
            'AZURE_USER_ASSIGNED_IDENTITY_ID',
            'AZURE_USER_ASSIGNED_IDENTITY_CLIENT_ID',
            'AZURE_FUNCTION_SUBNET_ID',
            'REGISTRY_IMAGE',
            'AZURE_ACR_TOKEN_NAME',
            'REGISTRY_PASSWORD'
        )) {
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    if ($parameterPath -and (Test-Path -LiteralPath $parameterPath)) {
        Remove-Item -LiteralPath $parameterPath -Force
    }
    if ($buildContext -and (Test-Path -LiteralPath $buildContext)) {
        Remove-Item -LiteralPath $buildContext -Recurse -Force
    }
    if ($publishRoot -and (Test-Path -LiteralPath $publishRoot)) {
        Remove-Item -LiteralPath $publishRoot -Recurse -Force
    }
    if ($helperDirectory -and (Test-Path -LiteralPath $helperDirectory)) {
        Remove-Item -LiteralPath $helperDirectory -Recurse -Force
    }
    $registryPassword = $null
    Pop-Location
}
