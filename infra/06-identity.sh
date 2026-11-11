#!/usr/bin/env bash
# Step 6: the app calls the model with its managed identity, and the Foundry
# API keys are turned off.
# Run with Git Bash after `az login`, after infra/05-aca.sh:
#   & "C:\Program Files\Git\bin\bash.exe" infra/06-identity.sh
#
# What it does:
#   1. Role "Cognitive Services OpenAI User" for the app's own identity, on the
#      Foundry resource only: it may call the model, nothing more.
#   2. Turns off the Foundry API keys (disableLocalAuth). Only Entra ID tokens
#      work afterwards: my `az login` on my PC, the managed identity in Azure.
# (The app's identity and its AcrPull role come from infra/05-aca.sh.)
set -euo pipefail

# Git Bash turns "/subscriptions/..." into a Windows path. This stops that.
export MSYS_NO_PATHCONV=1

RG="rg-calmops"
APP="ca-calmops"
FOUNDRY="foundry-calmops-ts"

# The principal ID changes when the app is created again, so look it up.
PRINCIPAL_ID=$(az containerapp show --name "$APP" --resource-group "$RG" --query identity.principalId --output tsv)
FOUNDRY_ID=$(az cognitiveservices account show --name "$FOUNDRY" --resource-group "$RG" --query id --output tsv)

echo "1/2 Role Cognitive Services OpenAI User for the app's identity ($PRINCIPAL_ID)"
# --assignee-principal-type: Azure doesn't look the identity up in Entra ID
# first, so it works even if the identity is a few seconds old.
# The role can take a few minutes before the first model call works.
az role assignment create \
  --assignee-object-id "$PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services OpenAI User" \
  --scope "$FOUNDRY_ID" \
  --output none

echo "2/2 Turn off the Foundry API keys"
# az cognitiveservices account update has no flag for this, so the general command.
az resource update \
  --ids "$FOUNDRY_ID" \
  --set properties.disableLocalAuth=true \
  --query "{disableLocalAuth:properties.disableLocalAuth}" --output table

# Undo only this step:
#   az resource update --ids "$FOUNDRY_ID" --set properties.disableLocalAuth=false
#   az role assignment delete --assignee "$PRINCIPAL_ID" --role "Cognitive Services OpenAI User" --scope "$FOUNDRY_ID"
