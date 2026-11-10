#!/usr/bin/env bash
# Step 4: Azure Container Registry (ACR), a private store for the CalmOps image.
# Run with Git Bash after `az login`:
#   & "C:\Program Files\Git\bin\bash.exe" infra/04-acr.sh
set -euo pipefail

# Git Bash turns "/subscriptions/..." into a Windows path. This stops that.
export MSYS_NO_PATHCONV=1

RG="rg-calmops"
LOCATION="germanywestcentral"
TAGS="project=calmops"
# Globally unique, 5-50 letters/digits, no dashes. Web address: acrcalmopsts.azurecr.io
ACR="acrcalmopsts"
# Basic: cheapest tier (about EUR 0.15/day, also when idle), 10 GB storage.
# Enough for one app. Geo-replication and private endpoints need Premium.
SKU="Basic"

echo "1/3 Turn on the registry service for this subscription (once; takes 1-2 min)"
# A new subscription can't create a resource type until its "resource provider"
# is registered. Without it: MissingSubscriptionRegistration (2026-11-10).
az provider register --namespace Microsoft.ContainerRegistry --wait
az provider show --namespace Microsoft.ContainerRegistry --query registrationState --output tsv

echo "2/3 Check that the name is free"
az acr check-name --name "$ACR" --query nameAvailable --output tsv

echo "3/3 Container registry (admin user off)"
# --admin-enabled false: no shared username/password. Container Apps will pull
# with its managed identity + the AcrPull role (step 6), I push with my Entra ID login.
az acr create \
  --name "$ACR" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --sku "$SKU" \
  --admin-enabled false \
  --tags $TAGS \
  --output table

echo "Login server:"
az acr show --name "$ACR" --resource-group "$RG" --query loginServer --output tsv

# Delete only this step again:
#   az acr delete --name "$ACR" --resource-group "$RG" --yes
