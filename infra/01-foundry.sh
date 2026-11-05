#!/usr/bin/env bash
# Step 1: Microsoft Foundry resource + project + gpt-5-mini deployment,
# and the right for me to call the model with my Entra ID login (no API key).
# Run with Git Bash after `az login`:  bash infra/01-foundry.sh
set -euo pipefail

# Git Bash turns "/subscriptions/..." into a Windows path. This stops that.
export MSYS_NO_PATHCONV=1

RG="rg-calmops"
LOCATION="germanywestcentral"
TAGS="project=calmops"
FOUNDRY="foundry-calmops-ts"   # also the web address: https://foundry-calmops-ts.cognitiveservices.azure.com
PROJECT="proj-calmops"

MODEL="gpt-5-mini"
MODEL_VERSION="2025-08-07"
DEPLOYMENT="gpt-5-mini"        # the name the code calls
# Where Azure may process the requests. DataZoneStandard (EU only) has 0 quota
# in this subscription (checked 2026-11-02), so we start with GlobalStandard.
# Switching later keeps the same deployment name, so the code does not change.
DEPLOYMENT_SKU="GlobalStandard"
# In 1000 tokens per minute (TPM). A speed limit, not a price: GlobalStandard
# bills per token used. 50 was too low for the eval sweep (4 conversations at
# once): 45 of 78 runs failed with 429 on 2026-11-05. The quota allows 500.
CAPACITY=250

echo "1/4 Foundry resource"
az cognitiveservices account create \
  --name "$FOUNDRY" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --kind AIServices \
  --sku S0 \
  --custom-domain "$FOUNDRY" \
  --allow-project-management \
  --tags $TAGS \
  --yes \
  --output table

echo "2/4 Project"
az cognitiveservices account project create \
  --name "$FOUNDRY" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --project-name "$PROJECT" \
  --output table

echo "3/4 Model deployment"
az cognitiveservices account deployment create \
  --name "$FOUNDRY" \
  --resource-group "$RG" \
  --deployment-name "$DEPLOYMENT" \
  --model-name "$MODEL" \
  --model-version "$MODEL_VERSION" \
  --model-format OpenAI \
  --sku-name "$DEPLOYMENT_SKU" \
  --sku-capacity "$CAPACITY" \
  --output table

echo "4/4 Role for me: Cognitive Services OpenAI User"
ME=$(az ad signed-in-user show --query id --output tsv)
FOUNDRY_ID=$(az cognitiveservices account show --name "$FOUNDRY" --resource-group "$RG" --query id --output tsv)
az role assignment create \
  --assignee-object-id "$ME" \
  --assignee-principal-type User \
  --role "Cognitive Services OpenAI User" \
  --scope "$FOUNDRY_ID" \
  --output table

echo "Endpoint:"
az cognitiveservices account show --name "$FOUNDRY" --resource-group "$RG" --query properties.endpoint --output tsv

# Delete only this step again:
#   az cognitiveservices account delete --name "$FOUNDRY" --resource-group "$RG"
#   az cognitiveservices account purge --name "$FOUNDRY" --resource-group "$RG" --location "$LOCATION"
