$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $repositoryRoot

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

$helperDirectory = $null
try {
    $dotnet = Get-DotnetCommand
    $helperDirectory = Join-Path ([IO.Path]::GetTempPath()) (
        "dotnet-deploy-helper-$([guid]::NewGuid().ToString('N'))"
    )
    New-Item -ItemType Directory -Path $helperDirectory | Out-Null
    & $dotnet publish `
        .\infra\scripts\DeployHelper\DeployHelper.csproj `
        --configuration Release `
        --output $helperDirectory `
        --nologo `
        -p:NuGetAudit=false |
        Out-Null
    $helper = Join-Path $helperDirectory 'DeployHelper.dll'
    $currentHash = (& $dotnet $helper source-hash).Trim()

    try {
        $deployedHash = (
            & azd env get-value AZURE_IMAGE_CONTEXT_HASH 2>$null
        ).Trim()
    } catch {
        $deployedHash = ''
    }
    try {
        $registryImage = (
            & azd env get-value AZURE_REGISTRY_IMAGE 2>$null
        ).Trim()
    } catch {
        $registryImage = ''
    }

    if ($currentHash -eq $deployedHash -and
        -not [string]::IsNullOrWhiteSpace($registryImage)) {
        $resourceGroup = (& azd env get-value AZURE_RESOURCE_GROUP).Trim()
        $functionAppName = (& azd env get-value AZURE_FUNCTION_NAME).Trim()
        try {
            & az functionapp start `
                --resource-group $resourceGroup `
                --name $functionAppName `
                --only-show-errors
            Write-Host "Image inputs are unchanged; keeping $registryImage"
        } catch {
            Write-Host 'The Function App is missing; redeploying the image.'
            & (Join-Path $PSScriptRoot 'deployimage.ps1')
        }
    } else {
        & (Join-Path $PSScriptRoot 'deployimage.ps1')
    }
} finally {
    if ($helperDirectory -and (Test-Path -LiteralPath $helperDirectory)) {
        Remove-Item -LiteralPath $helperDirectory -Recurse -Force
    }
    Pop-Location
}
