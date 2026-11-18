#!/usr/bin/env bash
# Step 9: the login secret lives in Key Vault, not in the container app.
# The app reads it with its managed identity (a Key Vault reference).
# Run with Git Bash after `az login`, after infra/07-auth.sh:
#   & "C:\Program Files\Git\bin\bash.exe" infra/09-keyvault.sh
#
# What it builds:
#   1. A key vault kv-calmops-ts = a safe for secrets. Standard tier, RBAC
#      (roles decide who may read secrets), soft delete 7 days (the minimum,
#      so a rebuild can reuse the name soon), purge protection off (it can
#      never be turned off again and would block a purge at teardown).
#      "Off" = leave the flag out: the API refuses an explicit false
#      ("cannot be set to false", first run 2026-11-18).
#   2. Role "Key Vault Secrets Officer" for me: Owner on the group only
#      manages the vault itself; writing a secret needs a data role.
#   3. Role "Key Vault Secrets User" for the app's identity: it may read
#      secret values in this vault, nothing more.
#   4. A new client secret for the login app calmops-login, written into the
#      vault as a new version of calmops-login-secret (never printed). Each
#      run = a rotation (like infra/07-auth.sh part 4, which it replaces).
#   5. The app secret login-secret = only a reference to the vault secret
#      (keyvaultref, no value). The URI has no version, so the app follows
#      new versions (Learn: within 30 minutes).
#   6. Easy Auth uses login-secret.
#   7. Removes the old app secret from step 7 (its value stopped working in
#      part 4).
# Secrets are app-level: no new revision.
# Not moved: the storage account key of step 8. Reading it from Key Vault
# needs the containerapp extension and is preview (2026-11).
# Safe to run again: parts 1 and 7 check first; 2, 3, 5, 6 just set it again.
set -euo pipefail

# Git Bash turns "/subscriptions/..." into a Windows path. This stops that.
export MSYS_NO_PATHCONV=1

RG="rg-calmops"
LOCATION="germanywestcentral"
APP="ca-calmops"
VAULT="kv-calmops-ts"
LOGIN_APP="calmops-login"
VAULT_SECRET="calmops-login-secret"
# An app secret name may have at most 20 characters (az containerapp secret set).
APP_SECRET="login-secret"
OLD_APP_SECRET="microsoft-provider-authentication-secret"

echo "1/7 Key vault $VAULT"
if ! az keyvault show --name "$VAULT" --resource-group "$RG" --output none 2>/dev/null; then
  az keyvault create --name "$VAULT" --resource-group "$RG" --location "$LOCATION" \
    --sku standard --enable-rbac-authorization true \
    --retention-days 7 \
    --tags project=calmops --output none
fi
VAULT_ID=$(az keyvault show --name "$VAULT" --resource-group "$RG" --query id --output tsv)
VAULT_URI=$(az keyvault show --name "$VAULT" --resource-group "$RG" --query properties.vaultUri --output tsv)

echo "2/7 Role Key Vault Secrets Officer for me"
USER_ID=$(az ad signed-in-user show --query id --output tsv)
az role assignment create --assignee-object-id "$USER_ID" --assignee-principal-type User \
  --role "Key Vault Secrets Officer" --scope "$VAULT_ID" --output none

echo "3/7 Role Key Vault Secrets User for the app's identity"
# The principal ID changes when the app is created again, so look it up.
PRINCIPAL_ID=$(az containerapp show --name "$APP" --resource-group "$RG" --query identity.principalId --output tsv)
az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" --scope "$VAULT_ID" --output none

echo "4/7 New client secret into the vault (waits until my role works)"
# A new role can take a few minutes (step 6: about 2). Wait before the reset,
# so the login is not broken while we wait.
until az keyvault secret list --vault-name "$VAULT" --output none 2>/dev/null; do
  echo "   role not active yet, waiting 20 s"
  sleep 20
done
APP_ID=$(az ad app list --display-name "$LOGIN_APP" --query "[0].appId" --output tsv)
# Without --append, this deletes the old secrets of the registration.
SECRET=$(az ad app credential reset --id "$APP_ID" --display-name easy-auth --years 1 --query password --output tsv)
az keyvault secret set --vault-name "$VAULT" --name "$VAULT_SECRET" --value "$SECRET" --output none
unset SECRET

echo "5/7 App secret $APP_SECRET = reference to the vault (no value)"
SECRET_URI="${VAULT_URI}secrets/$VAULT_SECRET"
# The app fetches the secret here, so its role (part 3) must be active.
for TRY in 1 2 3 4 5 6 7 8 9 10; do
  if az containerapp secret set --name "$APP" --resource-group "$RG" \
       --secrets "$APP_SECRET=keyvaultref:$SECRET_URI,identityref:system" --output none; then
    break
  fi
  if [ "$TRY" = 10 ]; then echo "Gave up: the app could not read the vault."; exit 1; fi
  echo "   app role not active yet, waiting 30 s"
  sleep 30
done

echo "6/7 Easy Auth uses $APP_SECRET"
az containerapp auth microsoft update --name "$APP" --resource-group "$RG" \
  --client-secret-name "$APP_SECRET" --yes --output none

echo "7/7 Remove the old app secret $OLD_APP_SECRET"
if [ -n "$(az containerapp secret list --name "$APP" --resource-group "$RG" --query "[?name=='$OLD_APP_SECRET'].name" --output tsv)" ]; then
  az containerapp secret remove --name "$APP" --resource-group "$RG" --secret-names "$OLD_APP_SECRET" --output none
fi

echo "Result"
az containerapp secret list --name "$APP" --resource-group "$RG" --query "[].{name:name, keyVaultUrl:keyVaultUrl, identity:identity}" --output table
az containerapp auth show --name "$APP" --resource-group "$RG" \
  --query "{clientSecretSettingName:identityProviders.azureActiveDirectory.registration.clientSecretSettingName}" --output table

# Check: a fresh login in a private browser window still works.
# Rotation = run this script again (new version; the app may need up to 30
#   minutes to pick it up, as the old value stops working at once).
# Undo only this step = run infra/07-auth.sh again: it makes a new secret,
#   stores it in the app and points Easy Auth back to it. Then
#   az containerapp secret remove --name ca-calmops --resource-group rg-calmops --secret-names login-secret
#   az keyvault delete --name kv-calmops-ts --resource-group rg-calmops
