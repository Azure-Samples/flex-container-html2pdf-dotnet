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

HELPER_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/dotnet-deploy-helper.XXXXXX")
cleanup() {
    case "$HELPER_DIRECTORY" in
        "${TMPDIR:-/tmp}"/dotnet-deploy-helper.*)
            rm -rf -- "$HELPER_DIRECTORY"
            ;;
        *)
            echo "Refusing to remove unexpected helper: $HELPER_DIRECTORY" >&2
            ;;
    esac
}
trap cleanup EXIT INT TERM

dotnet publish \
    ./infra/scripts/DeployHelper/DeployHelper.csproj \
    --configuration Release \
    --output "$HELPER_DIRECTORY" \
    --nologo \
    -p:NuGetAudit=false \
    >/dev/null
HELPER_DLL="$HELPER_DIRECTORY/DeployHelper.dll"
CURRENT_HASH=$(dotnet "$HELPER_DLL" source-hash)
DEPLOYED_HASH=$(azd env get-value AZURE_IMAGE_CONTEXT_HASH 2>/dev/null || true)
REGISTRY_IMAGE=$(azd env get-value AZURE_REGISTRY_IMAGE 2>/dev/null || true)

if [ "$CURRENT_HASH" = "$DEPLOYED_HASH" ] && [ -n "$REGISTRY_IMAGE" ]; then
    AZURE_RESOURCE_GROUP=$(azd env get-value AZURE_RESOURCE_GROUP)
    AZURE_FUNCTION_NAME=$(azd env get-value AZURE_FUNCTION_NAME)
    if az functionapp start \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --name "$AZURE_FUNCTION_NAME" \
        --only-show-errors; then
        echo "Image inputs are unchanged; keeping $REGISTRY_IMAGE"
    else
        echo "The Function App is missing; redeploying the image."
        sh "$SCRIPT_DIR/deployimage.sh"
    fi
else
    sh "$SCRIPT_DIR/deployimage.sh"
fi
