#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
cd "$REPOSITORY_ROOT"

if ! command -v dotnet >/dev/null 2>&1; then
    echo ".NET 10 SDK or later is required for the deployment helper." >&2
    exit 1
fi
if ! dotnet --list-sdks | awk '
    {
        split($1, version, ".")
        if (version[1] + 0 >= 10) {
            found = 1
        }
    }
    END { exit found ? 0 : 1 }
'; then
    echo ".NET 10 SDK or later is required for the deployment helper." >&2
    exit 1
fi

get_azd_value() {
    name=$1
    eval "value=\${$name:-}"
    if [ -z "$value" ]; then
        value=$(azd env get-value "$name")
    fi
    if [ -z "$value" ]; then
        echo "Required azd environment value '$name' is missing." >&2
        exit 1
    fi
    printf '%s' "$value"
}

TEMPORARY_DIRECTORY=
HELPER_DIRECTORY=
cleanup() {
    if [ -n "$TEMPORARY_DIRECTORY" ] && [ -d "$TEMPORARY_DIRECTORY" ]; then
        case "$TEMPORARY_DIRECTORY" in
            "${TMPDIR:-/tmp}"/dotnet-pdf-verification.*)
                rm -rf -- "$TEMPORARY_DIRECTORY"
                ;;
            *)
                echo "Refusing to remove unexpected path: $TEMPORARY_DIRECTORY" >&2
                ;;
        esac
    fi
    if [ -n "$HELPER_DIRECTORY" ] && [ -d "$HELPER_DIRECTORY" ]; then
        case "$HELPER_DIRECTORY" in
            "${TMPDIR:-/tmp}"/dotnet-deploy-helper.*)
                rm -rf -- "$HELPER_DIRECTORY"
                ;;
            *)
                echo "Refusing to remove unexpected helper: $HELPER_DIRECTORY" >&2
                ;;
        esac
    fi
}
trap cleanup EXIT INT TERM

AZURE_SUBSCRIPTION_ID=$(get_azd_value AZURE_SUBSCRIPTION_ID)
AZURE_ENV_NAME=$(get_azd_value AZURE_ENV_NAME)
AZURE_RESOURCE_GROUP=$(get_azd_value AZURE_RESOURCE_GROUP)
AZURE_FUNCTION_NAME=$(get_azd_value AZURE_FUNCTION_NAME)
API_URL=$(get_azd_value API_URL)
AZURE_REGISTRY_IMAGE=$(get_azd_value AZURE_REGISTRY_IMAGE)
AZURE_FUNCTION_SUBNET_ID=$(get_azd_value AZURE_FUNCTION_SUBNET_ID)
AZURE_USER_ASSIGNED_IDENTITY_ID=$(
    get_azd_value AZURE_USER_ASSIGNED_IDENTITY_ID
)
AZURE_USER_ASSIGNED_IDENTITY_PRINCIPAL_ID=$(
    get_azd_value AZURE_USER_ASSIGNED_IDENTITY_PRINCIPAL_ID
)
AZURE_STORAGE_ACCOUNT_ID=$(get_azd_value AZURE_STORAGE_ACCOUNT_ID)
AZURE_APPLICATION_INSIGHTS_ID=$(
    get_azd_value AZURE_APPLICATION_INSIGHTS_ID
)
AZURE_APPLICATION_INSIGHTS_NAME=$(
    get_azd_value AZURE_APPLICATION_INSIGHTS_NAME
)
AZURE_IMAGE_CONTEXT_HASH=$(get_azd_value AZURE_IMAGE_CONTEXT_HASH)
AZURE_IMAGE_BUILD_ACTION=$(get_azd_value AZURE_IMAGE_BUILD_ACTION)
AZURE_IMAGE_DIGEST=$(get_azd_value AZURE_IMAGE_DIGEST)
API_URL=${API_URL%/}
HOST_NAME=${API_URL#https://}
SITE_ID="/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$AZURE_RESOURCE_GROUP/providers/Microsoft.Web/sites/$AZURE_FUNCTION_NAME"

az account set --subscription "$AZURE_SUBSCRIPTION_ID"

TEMPORARY_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/dotnet-pdf-verification.XXXXXX")
HELPER_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/dotnet-deploy-helper.XXXXXX")
dotnet publish \
    ./infra/scripts/DeployHelper/DeployHelper.csproj \
    --configuration Release \
    --output "$HELPER_DIRECTORY" \
    --nologo \
    -p:NuGetAudit=false \
    >/dev/null
HELPER_DLL="$HELPER_DIRECTORY/DeployHelper.dll"
if [ ! -f "$HELPER_DLL" ]; then
    echo "Deployment helper was not published: $HELPER_DLL" >&2
    exit 1
fi
run_helper() {
    dotnet "$HELPER_DLL" "$@"
}

DEADLINE=$(( $(date +%s) + 360 ))
LEAF_NAMES=
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    FUNCTION_NAMES=$(az rest \
        --method get \
        --url "https://management.azure.com$SITE_ID/functions?api-version=2026-08-01" \
        --query 'value[].name' \
        --output tsv 2>/dev/null || true)
    LEAF_NAMES=$(printf '%s\n' "$FUNCTION_NAMES" | awk -F/ 'NF { print $NF }')
    FUNCTION_COUNT=$(printf '%s\n' "$LEAF_NAMES" | awk 'NF { count++ } END { print count + 0 }')
    if [ "$FUNCTION_COUNT" -eq 2 ] &&
        printf '%s\n' "$LEAF_NAMES" | grep -Fxq 'Hello' &&
        printf '%s\n' "$LEAF_NAMES" | grep -Fxq 'HtmlToPdf'; then
        MASTER_KEY=$(az functionapp keys list \
            --resource-group "$AZURE_RESOURCE_GROUP" \
            --name "$AZURE_FUNCTION_NAME" \
            --query masterKey \
            --output tsv 2>/dev/null || true)
        HOST_STATUS=$(curl --silent --show-error --max-time 30 \
            --header "x-functions-key: $MASTER_KEY" \
            --output "$TEMPORARY_DIRECTORY/host-status.body" \
            --write-out '%{http_code}' \
            "https://$HOST_NAME/admin/host/status" 2>/dev/null || true)
        MASTER_KEY=
        if [ "$HOST_STATUS" = "200" ]; then
            break
        fi
    fi
    sleep 10
done

if [ "${FUNCTION_COUNT:-0}" -ne 2 ] ||
    ! printf '%s\n' "$LEAF_NAMES" | grep -Fxq 'Hello' ||
    ! printf '%s\n' "$LEAF_NAMES" | grep -Fxq 'HtmlToPdf' ||
    [ "${HOST_STATUS:-}" != "200" ]; then
    echo "The worker did not become ready within six minutes." >&2
    exit 1
fi

new_trace_context() {
    TRACE_OUTPUT=$(run_helper trace-context)
    TRACE_ID=$(printf '%s\n' "$TRACE_OUTPUT" | sed -n '1p')
    TRACE_PARENT=$(printf '%s\n' "$TRACE_OUTPUT" | sed -n '2p')
}

curl_request() {
    name=$1
    shift
    new_trace_context
    REQUEST_HEADERS="$TEMPORARY_DIRECTORY/$name.headers"
    REQUEST_BODY="$TEMPORARY_DIRECTORY/$name.body"
    REQUEST_STATUS=$(curl --silent --show-error --max-time 120 \
        --header "traceparent: $TRACE_PARENT" \
        --dump-header "$REQUEST_HEADERS" \
        --output "$REQUEST_BODY" \
        --write-out '%{http_code}' \
        "$@")
    REQUEST_TRACE_ID=$TRACE_ID
}

VERIFICATION_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)

curl_request hello-get "$API_URL/api/hello"
HELLO_GET_STATUS=$REQUEST_STATUS
HELLO_GET_TRACE_ID=$REQUEST_TRACE_ID
if [ "$HELLO_GET_STATUS" != "200" ] ||
    [ "$(cat "$REQUEST_BODY")" != "Hello from the .NET worker." ]; then
    echo "Hello GET did not return the exact expected response." >&2
    exit 1
fi

curl_request hello-post --request POST "$API_URL/api/hello"
HELLO_POST_STATUS=$REQUEST_STATUS
HELLO_POST_TRACE_ID=$REQUEST_TRACE_ID
if [ "$HELLO_POST_STATUS" != "200" ] ||
    [ "$(cat "$REQUEST_BODY")" != "Hello from the .NET worker." ]; then
    echo "Hello POST did not return the exact expected response." >&2
    exit 1
fi

curl_request pdf-get "$API_URL/api/html-to-pdf"
PDF_GET_STATUS=$REQUEST_STATUS
PDF_GET_TRACE_ID=$REQUEST_TRACE_ID
PDF_GET_BYTES=$(run_helper validate-pdf "$REQUEST_BODY" | awk '{ print $(NF - 1) }')
PDF_GET_CONTENT_TYPE=$(awk '
    BEGIN { IGNORECASE = 1 }
    /^Content-Type:/ {
        sub(/^[^:]*:[[:space:]]*/, "")
        value = $0
    }
    END {
        gsub(/\r/, "", value)
        print value
    }
' "$REQUEST_HEADERS")
if [ "$PDF_GET_STATUS" != "200" ] ||
    ! printf '%s' "$PDF_GET_CONTENT_TYPE" | grep -Eq '^application/pdf'; then
    echo "HTML-to-PDF GET did not return a valid PDF response." >&2
    exit 1
fi

curl_request pdf-post \
    --request POST \
    --header 'Content-Type: text/html; charset=utf-8' \
    --data-binary @sample.html \
    "$API_URL/api/html-to-pdf"
PDF_POST_STATUS=$REQUEST_STATUS
PDF_POST_TRACE_ID=$REQUEST_TRACE_ID
PDF_POST_BYTES=$(run_helper validate-pdf "$REQUEST_BODY" | awk '{ print $(NF - 1) }')
PDF_POST_CONTENT_TYPE=$(awk '
    BEGIN { IGNORECASE = 1 }
    /^Content-Type:/ {
        sub(/^[^:]*:[[:space:]]*/, "")
        value = $0
    }
    END {
        gsub(/\r/, "", value)
        print value
    }
' "$REQUEST_HEADERS")
if [ "$PDF_POST_STATUS" != "200" ] ||
    ! printf '%s' "$PDF_POST_CONTENT_TYPE" | grep -Eq '^application/pdf'; then
    echo "HTML-to-PDF POST did not return a valid PDF response." >&2
    exit 1
fi

curl_request pdf-invalid-json \
    --request POST \
    --header 'Content-Type: application/json' \
    --data-binary '{}' \
    "$API_URL/api/html-to-pdf"
INVALID_STATUS=$REQUEST_STATUS
INVALID_TRACE_ID=$REQUEST_TRACE_ID
if [ "$INVALID_STATUS" != "415" ] ||
    ! grep -Fq 'unsupported_media_type' "$REQUEST_BODY"; then
    echo "The endpoint did not reject application/json with HTTP 415." >&2
    exit 1
fi

SITE_JSON=$(az rest \
    --method get \
    --url "https://management.azure.com$SITE_ID?api-version=2026-08-01" \
    --query '{state:properties.state,type:properties.functionAppConfig.deployment.storage.type,value:properties.functionAppConfig.deployment.storage.value,subnet:properties.virtualNetworkSubnetId,identityType:identity.type,identityIds:keys(identity.userAssignedIdentities),httpsOnly:properties.httpsOnly}' \
    --output json)
WEB_CONFIG_JSON=$(az rest \
    --method get \
    --url "https://management.azure.com$SITE_ID/config/web?api-version=2022-03-01" \
    --query '{minTlsVersion:properties.minTlsVersion,scmMinTlsVersion:properties.scmMinTlsVersion,ftpsState:properties.ftpsState,http20Enabled:properties.http20Enabled,remoteDebuggingEnabled:properties.remoteDebuggingEnabled}' \
    --output json)
FTP_POLICY_JSON=$(az rest \
    --method get \
    --url "https://management.azure.com$SITE_ID/basicPublishingCredentialsPolicies/ftp?api-version=2022-03-01" \
    --output json)
SCM_POLICY_JSON=$(az rest \
    --method get \
    --url "https://management.azure.com$SITE_ID/basicPublishingCredentialsPolicies/scm?api-version=2022-03-01" \
    --output json)
export SITE_JSON WEB_CONFIG_JSON FTP_POLICY_JSON SCM_POLICY_JSON
export AZURE_REGISTRY_IMAGE AZURE_FUNCTION_SUBNET_ID
export AZURE_USER_ASSIGNED_IDENTITY_ID
run_helper validate-site

SETTING_NAMES=$(az rest \
    --method post \
    --url "https://management.azure.com$SITE_ID/config/appsettings/list?api-version=2026-08-01" \
    --query 'keys(properties)' \
    --output tsv)
for forbidden in \
    FUNCTIONS_APPLICATION_DIRECTORY \
    AzureWebJobsScriptRoot \
    WEBSITE_RUN_FROM_PACKAGE
do
    if printf '%s\n' "$SETTING_NAMES" | grep -Fxq "$forbidden"; then
        echo "Forbidden application setting '$forbidden' is present." >&2
        exit 1
    fi
done

STORAGE_ROLE=$(az role assignment list \
    --assignee-object-id "$AZURE_USER_ASSIGNED_IDENTITY_PRINCIPAL_ID" \
    --scope "$AZURE_STORAGE_ACCOUNT_ID" \
    --query "[?roleDefinitionName=='Storage Blob Data Owner'].roleDefinitionName | [0]" \
    --output tsv)
MONITORING_ROLE=$(az role assignment list \
    --assignee-object-id "$AZURE_USER_ASSIGNED_IDENTITY_PRINCIPAL_ID" \
    --scope "$AZURE_APPLICATION_INSIGHTS_ID" \
    --query "[?roleDefinitionName=='Monitoring Metrics Publisher'].roleDefinitionName | [0]" \
    --output tsv)
if [ "$STORAGE_ROLE" != "Storage Blob Data Owner" ] ||
    [ "$MONITORING_ROLE" != "Monitoring Metrics Publisher" ]; then
    echo "The managed-identity role assignments do not match." >&2
    exit 1
fi

TRACE_LIST="'$HELLO_GET_TRACE_ID','$HELLO_POST_TRACE_ID','$PDF_GET_TRACE_ID','$PDF_POST_TRACE_ID','$INVALID_TRACE_ID'"
APP_ID=$(az monitor app-insights component show \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --app "$AZURE_APPLICATION_INSIGHTS_NAME" \
    --query appId \
    --output tsv)
REQUEST_ROWS=
ATTEMPT=1
while [ "$ATTEMPT" -le 12 ]; do
    QUERY="requests | where timestamp >= datetime($VERIFICATION_START) | where operation_Id in ($TRACE_LIST) | project operation_Id, success, resultCode"
    REQUEST_ROWS=$(az monitor app-insights query \
        --app "$APP_ID" \
        --analytics-query "$QUERY" \
        --query 'tables[0].rows' \
        --output tsv)
    REQUEST_COUNT=$(printf '%s\n' "$REQUEST_ROWS" | awk 'NF { count++ } END { print count + 0 }')
    if [ "$REQUEST_COUNT" -ge 5 ]; then
        break
    fi
    ATTEMPT=$((ATTEMPT + 1))
    sleep 15
done

APPINSIGHTS_REQUEST_COUNT=$(
    printf '%s\n' "$REQUEST_ROWS" |
        awk 'NF { count++ } END { print count + 0 }'
)
APPINSIGHTS_FAILED_REQUEST_COUNT=$(
    printf '%s\n' "$REQUEST_ROWS" |
        awk 'NF && tolower($2) != "true" { count++ } END { print count + 0 }'
)
if [ "$APPINSIGHTS_REQUEST_COUNT" -ne 5 ] ||
    [ "$APPINSIGHTS_FAILED_REQUEST_COUNT" -ne 0 ]; then
    echo "Application Insights request verification failed." >&2
    exit 1
fi
for trace_id in \
    "$HELLO_GET_TRACE_ID" \
    "$HELLO_POST_TRACE_ID" \
    "$PDF_GET_TRACE_ID" \
    "$PDF_POST_TRACE_ID" \
    "$INVALID_TRACE_ID"
do
    if ! printf '%s\n' "$REQUEST_ROWS" |
        awk '{ print $1 }' |
        grep -Fxq "$trace_id"; then
        echo "Application Insights is missing trace '$trace_id'." >&2
        exit 1
    fi
done

VERIFIED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
azd env set AZURE_VERIFIED_UTC "$VERIFIED_UTC" --no-prompt >/dev/null

STORAGE_ROLE_VERIFIED=true
MONITORING_ROLE_VERIFIED=true
export AZURE_FUNCTION_NAME AZURE_REGISTRY_IMAGE
export AZURE_IMAGE_CONTEXT_HASH AZURE_IMAGE_BUILD_ACTION AZURE_IMAGE_DIGEST
export LEAF_NAMES HELLO_GET_STATUS HELLO_POST_STATUS
export PDF_GET_BYTES PDF_POST_BYTES INVALID_STATUS
export APPINSIGHTS_REQUEST_COUNT APPINSIGHTS_FAILED_REQUEST_COUNT
export STORAGE_ROLE_VERIFIED MONITORING_ROLE_VERIFIED VERIFIED_UTC
VERIFICATION_JSON=$(run_helper verification-json)
VERIFICATION_DIRECTORY=".azure/$AZURE_ENV_NAME"
mkdir -p "$VERIFICATION_DIRECTORY"
printf '%s\n' "$VERIFICATION_JSON" >"$VERIFICATION_DIRECTORY/verification.json"
printf '%s\n' "$VERIFICATION_JSON"
echo "Verification evidence: $VERIFICATION_DIRECTORY/verification.json"
