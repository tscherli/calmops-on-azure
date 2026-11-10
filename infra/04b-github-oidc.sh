#!/usr/bin/env bash
# Step 4b: let GitHub Actions push images to ACR, with OIDC instead of a password.
# Run with Git Bash after `az login`:
#   & "C:\Program Files\Git\bin\bash.exe" infra/04b-github-oidc.sh
#
# What it builds:
#   1. An Entra ID app registration "github-calmops-on-azure" = the identity GitHub uses.
#      It lives in Entra ID, not in rg-calmops, so deleting the group does not delete it,
#      and its client ID in the GitHub settings stays valid after a rebuild.
#   2. Its service principal = the "user account" of that app in this tenant (roles go here).
#   3. A federated credential: Azure trusts GitHub's OIDC token, but only for pushes
#      to the main branch of tscherli/calmops-on-azure. No secret is created.
#   4. The role AcrPush on the registry only (least privilege: not the group, not the subscription).
# Safe to run again: each part is reused if it already exists.
set -euo pipefail

# Git Bash turns "/subscriptions/..." into a Windows path. This stops that.
export MSYS_NO_PATHCONV=1

RG="rg-calmops"
ACR="acrcalmopsts"
APP_NAME="github-calmops-on-azure"
CRED_NAME="github-main"
# GitHub writes this "subject" into the token of a run on the main branch.
# It holds the ID numbers of the owner and the repo, not only the names
# (found on the first run, 2026-11-10: the name-only subject was refused).
# IDs can't be taken over: a new repo with the same name, after a delete or a
# rename, gets a new ID, so its runs would not get in.
# Look them up: https://api.github.com/repos/tscherli/calmops-on-azure
#   owner.id = 87180788 (tscherli), id = 1447259309 (calmops-on-azure)
REPO="tscherli@87180788/calmops-on-azure@1447259309"
SUBJECT="repo:${REPO}:ref:refs/heads/main"

echo "1/4 App registration"
APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" --output tsv)
if [ -z "$APP_ID" ]; then
  APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId --output tsv)
  echo "    created, client ID $APP_ID"
else
  echo "    exists, client ID $APP_ID"
fi

echo "2/4 Service principal"
SP_ID=$(az ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" --output tsv)
if [ -z "$SP_ID" ]; then
  SP_ID=$(az ad sp create --id "$APP_ID" --query id --output tsv)
  echo "    created, object ID $SP_ID"
else
  echo "    exists, object ID $SP_ID"
fi

echo "3/4 Federated credential (trust GitHub, main branch only)"
CRED_JSON="{
  \"name\": \"$CRED_NAME\",
  \"issuer\": \"https://token.actions.githubusercontent.com\",
  \"subject\": \"$SUBJECT\",
  \"audiences\": [\"api://AzureADTokenExchange\"]
}"
HAS_CRED=$(az ad app federated-credential list --id "$APP_ID" --query "length([?name=='$CRED_NAME'])" --output tsv)
if [ "$HAS_CRED" = "0" ]; then
  az ad app federated-credential create --id "$APP_ID" --parameters "$CRED_JSON" --output none
  echo "    created"
else
  # Exists: set it again, so a changed subject in this script reaches Azure.
  az ad app federated-credential update --id "$APP_ID" --federated-credential-id "$CRED_NAME" --parameters "$CRED_JSON"
  echo "    updated"
fi
az ad app federated-credential list --id "$APP_ID" --query "[?name=='$CRED_NAME'].{name:name, subject:subject}" --output table

echo "4/4 Role AcrPush on the registry only"
# The assignment is deleted with the registry, so a rebuild must run this step again.
ACR_ID=$(az acr show --name "$ACR" --resource-group "$RG" --query id --output tsv)
az role assignment create \
  --assignee-object-id "$SP_ID" \
  --assignee-principal-type ServicePrincipal \
  --role AcrPush \
  --scope "$ACR_ID" \
  --query "{scope:scope}" --output table
# (create returns the role only as an ID. Check by name:
#  az role assignment list --assignee "$SP_ID" --all --query "[].roleDefinitionName")

echo
echo "GitHub repository variables (Settings > Secrets and variables > Actions > Variables):"
echo "  AZURE_CLIENT_ID       = $APP_ID"
echo "  AZURE_TENANT_ID       = $(az account show --query tenantId --output tsv)"
echo "  AZURE_SUBSCRIPTION_ID = $(az account show --query id --output tsv)"

# Delete only this step again (the app registration is outside rg-calmops):
#   az ad app delete --id <client ID>
