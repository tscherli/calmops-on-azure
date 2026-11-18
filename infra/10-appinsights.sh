#!/usr/bin/env bash
# Step 10: Application Insights = see requests, errors, latency and token use
# of the running app. The code side is in api.py (configure_azure_monitor)
# and observability/tracing.py (one "turn finished" record per turn).
# Run with Git Bash after `az login`, after infra/05-aca.sh:
#   & "C:\Program Files\Git\bin\bash.exe" infra/10-appinsights.sh
#
# What it builds:
#   1. Looks up the Log Analytics workspace log-calmops (step 5).
#   2. An Application Insights resource appi-calmops, "workspace-based": its
#      data is stored in log-calmops (30 days, same bill), next to the
#      container logs. Made with `az resource create`, because
#      `az monitor app-insights` needs an az extension that is preview only
#      (2026-11), and we use no preview extensions (same as step 8).
#   3. Reads its connection string = the address the app sends to. It only
#      lets you send data in, not read anything, so it is a plain setting,
#      not a secret.
#   4. Sets two environment variables on the app:
#      APPLICATIONINSIGHTS_CONNECTION_STRING (the code starts sending only
#      when it is set) and OTEL_SERVICE_NAME=calmops (the app's name in the
#      Application Map, instead of "unknown_service").
#      Environment variables are in the template: a new revision.
#   5. Shows the result.
# Safe to run again: part 2 checks first; part 4 just sets the same values
# (no change = no new revision).
set -euo pipefail

# Git Bash turns "/subscriptions/..." into a Windows path. This stops that.
export MSYS_NO_PATHCONV=1

RG="rg-calmops"
LOCATION="germanywestcentral"
APP="ca-calmops"
LOGS="log-calmops"
APPI="appi-calmops"
APPI_TYPE="Microsoft.Insights/components"
APPI_API="2020-02-02"

echo "1/5 Workspace $LOGS"
LOGS_ID=$(az monitor log-analytics workspace show --resource-group "$RG" --workspace-name "$LOGS" \
  --query id --output tsv)

echo "2/5 Application Insights $APPI"
if ! az resource show --resource-group "$RG" --name "$APPI" --resource-type "$APPI_TYPE" \
    --api-version "$APPI_API" --output none 2>/dev/null; then
  az resource create --resource-group "$RG" --name "$APPI" --resource-type "$APPI_TYPE" \
    --api-version "$APPI_API" --is-full-object --output none --properties "{
      \"location\": \"$LOCATION\",
      \"kind\": \"web\",
      \"tags\": {\"project\": \"calmops\"},
      \"properties\": {
        \"Application_Type\": \"web\",
        \"WorkspaceResourceId\": \"$LOGS_ID\",
        \"IngestionMode\": \"LogAnalytics\"
      }
    }"
fi

echo "3/5 Connection string"
CONNECTION_STRING=$(az resource show --resource-group "$RG" --name "$APPI" --resource-type "$APPI_TYPE" \
  --api-version "$APPI_API" --query properties.ConnectionString --output tsv)

echo "4/5 Environment variables on $APP (new revision)"
az containerapp update --name "$APP" --resource-group "$RG" \
  --set-env-vars "APPLICATIONINSIGHTS_CONNECTION_STRING=$CONNECTION_STRING" "OTEL_SERVICE_NAME=calmops" \
  --output none

echo "5/5 Result"
az resource show --resource-group "$RG" --name "$APPI" --resource-type "$APPI_TYPE" \
  --api-version "$APPI_API" \
  --query "{name:name, workspace:properties.WorkspaceResourceId, ingestion:properties.IngestionMode}" \
  --output table
az containerapp show --name "$APP" --resource-group "$RG" \
  --query "{revision:properties.latestRevisionName, env:join(', ', properties.template.containers[0].env[].name)}" \
  --output table
