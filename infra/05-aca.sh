#!/usr/bin/env bash
# Step 5: Azure Container Apps, which runs the CalmOps image with an HTTPS address.
# Run with Git Bash after `az login`:
#   & "C:\Program Files\Git\bin\bash.exe" infra/05-aca.sh
#
# What it builds:
#   1. Log Analytics workspace "log-calmops": where the app's log lines are stored.
#   2. Container Apps environment "cae-calmops": the shared "building" the app lives in.
#   3. Container app "ca-calmops": runs the newest image from ACR, pinned by digest.
#      It pulls with its own managed identity (AcrPull role), no password.
#   4. An IP rule: only my current public IP may open the app, until the
#      Entra ID login in step 7. Model calls fail until step 6 anyway.
set -euo pipefail

# Git Bash turns "/subscriptions/..." into a Windows path. This stops that.
export MSYS_NO_PATHCONV=1

RG="rg-calmops"
LOCATION="germanywestcentral"
TAGS="project=calmops"
LOGS="log-calmops"
ENV_NAME="cae-calmops"
APP="ca-calmops"
ACR="acrcalmopsts"
ACR_SERVER="acrcalmopsts.azurecr.io"
REPO="calmops"
FOUNDRY_ENDPOINT="https://foundry-calmops-ts.cognitiveservices.azure.com/"

echo "1/9 Turn on the Container Apps and Log Analytics services (once; 1-2 min each)"
# Both were NotRegistered in this subscription (checked 2026-11-11).
az provider register --namespace Microsoft.App --wait
az provider register --namespace Microsoft.OperationalInsights --wait

echo "2/9 Log Analytics workspace (30 days, pay per GB of logs)"
az monitor log-analytics workspace create \
  --workspace-name "$LOGS" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --retention-time 30 \
  --tags $TAGS \
  --query "{name:name, state:provisioningState}" --output table
LOGS_ID=$(az monitor log-analytics workspace show --workspace-name "$LOGS" --resource-group "$RG" --query customerId --output tsv)
# The key stays in this variable: never printed, never saved.
LOGS_KEY=$(az monitor log-analytics workspace get-shared-keys --workspace-name "$LOGS" --resource-group "$RG" --query primarySharedKey --output tsv)

echo "3/9 Container Apps environment (takes 2-5 min)"
# Consumption plan: no cost while no replica runs.
az containerapp env create \
  --name "$ENV_NAME" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --logs-workspace-id "$LOGS_ID" \
  --logs-workspace-key "$LOGS_KEY" \
  --tags $TAGS \
  --query "{name:name, state:properties.provisioningState}" --output table

echo "4/9 Newest image in the registry (pushed by CI), pinned by digest"
# A tag can be overwritten by a later push (AcrPush allows that). A digest is
# the hash of the image content, so it always means exactly this image, also
# when a replica starts again from 0.
DIGEST=$(az acr manifest list-metadata --registry "$ACR" --name "$REPO" --orderby time_desc --query "[0].digest" --output tsv 2>/dev/null)
TAG=$(az acr manifest list-metadata --registry "$ACR" --name "$REPO" --orderby time_desc --query "[0].tags[0]" --output tsv 2>/dev/null)
IMAGE="$ACR_SERVER/$REPO@$DIGEST"
echo "    tag    $TAG"
echo "    image  $IMAGE"

echo "5/9 Container app with Azure's placeholder image (takes 1-3 min)"
# Chicken and egg: the app's own identity exists only after the app exists, and
# it can pull from ACR only after it has AcrPull. So: create the app with a public
# placeholder image first, then give the role, then switch to my image (7-9).
# (--registry-identity system does the same in one command, but it stopped after
# this part on 2026-11-11 with InternalServerError, so the parts are done one by one.)
# --system-assigned: the app gets its own managed identity (an ID card, no password).
# --min-replicas 0: no replica (and no cost) when nobody uses it. First request then waits.
# --max-replicas 1: the approval pause lives in one process's memory (InMemorySaver),
#   and it also limits how much a stranger could spend.
az containerapp create \
  --name "$APP" \
  --resource-group "$RG" \
  --environment "$ENV_NAME" \
  --image mcr.microsoft.com/k8se/quickstart:latest \
  --system-assigned \
  --ingress external \
  --target-port 8000 \
  --min-replicas 0 \
  --max-replicas 1 \
  --cpu 0.5 \
  --memory 1.0Gi \
  --env-vars "AZURE_OPENAI_ENDPOINT=$FOUNDRY_ENDPOINT" OPENAI_ENABLE_WEB_SEARCH=true LANGSMITH_TRACING=false \
  --tags $TAGS \
  --query "{name:name, state:properties.provisioningState}" --output table

echo "6/9 Only my public IP may open the app (until the login in step 7)"
# api.ipify.org only answers with the IP address it sees. Nothing is sent to it.
MY_IP=$(curl -s https://api.ipify.org)
az containerapp ingress access-restriction set \
  --name "$APP" \
  --resource-group "$RG" \
  --rule-name only-me \
  --ip-address "$MY_IP/32" \
  --action Allow \
  --description "Until the Entra ID login (step 7)" \
  --output none
echo "    allowed: $MY_IP (if my IP changes, run this step again)"

echo "7/9 Role AcrPull for the app's identity, on the registry only"
# --assignee-principal-type: Azure doesn't look the new identity up in Entra ID
# first, so it works even if the identity is a few seconds old.
PRINCIPAL_ID=$(az containerapp show --name "$APP" --resource-group "$RG" --query identity.principalId --output tsv)
ACR_ID=$(az acr show --name "$ACR" --resource-group "$RG" --query id --output tsv)
az role assignment create \
  --assignee-object-id "$PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role AcrPull \
  --scope "$ACR_ID" \
  --output none

echo "8/9 Tell the app to log in to ACR with its identity"
az containerapp registry set \
  --name "$APP" \
  --resource-group "$RG" \
  --server "$ACR_SERVER" \
  --identity system \
  --output none

echo "9/9 Switch to my image (new revision)"
az containerapp update \
  --name "$APP" \
  --resource-group "$RG" \
  --image "$IMAGE" \
  --query "{revision:properties.latestRevisionName, state:properties.provisioningState}" --output table

echo
echo "Address (don't share it before step 7):"
echo "  https://$(az containerapp show --name "$APP" --resource-group "$RG" --query properties.configuration.ingress.fqdn --output tsv)/health"

# Delete only this step again:
#   az containerapp delete --name "$APP" --resource-group "$RG" --yes
#   az containerapp env delete --name "$ENV_NAME" --resource-group "$RG" --yes
#   az monitor log-analytics workspace delete --workspace-name "$LOGS" --resource-group "$RG" --yes
