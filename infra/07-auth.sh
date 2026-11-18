#!/usr/bin/env bash
# Step 7: only I may open the app. Login with Entra ID (Container Apps
# built-in authentication, "Easy Auth").
# Run with Git Bash after `az login`, after infra/05-aca.sh:
#   & "C:\Program Files\Git\bin\bash.exe" infra/07-auth.sh
#
# What it builds:
#   1. An Entra ID app registration "calmops-login" = the app's entry in my
#      tenant's login system. Single tenant: only accounts of my tenant can sign
#      in. Like the GitHub one (step 4b) it lives in Entra ID, not in rg-calmops.
#      Its redirect URI is the app's URL, so it is set again on every run
#      (a rebuilt app gets a new URL).
#   2. Its service principal (enterprise application) with "assignment required":
#      a tenant account that isn't on its list is refused at the login.
#   3. One assignment: my own account. Nobody else is on the list.
#   4. A new client secret for the login, written straight into the app
#      (never printed). Each run replaces the old secrets = a rotation.
#      Since step 9 the secret lives in Key Vault: infra/09-keyvault.sh moves
#      it there and does the rotation. A rerun of this script after step 9
#      puts the secret back into the app (= undo of step 9).
#   5. Easy Auth on the container app: every request without a valid login is
#      sent to the Microsoft login page, before it reaches my code.
#   6. Removes the IP rule "only-me" (step 5): the login replaces it.
# Safe to run again: parts 1-3 and 6 check first.
set -euo pipefail

# Git Bash turns "/subscriptions/..." into a Windows path. This stops that.
export MSYS_NO_PATHCONV=1

RG="rg-calmops"
APP="ca-calmops"
LOGIN_APP="calmops-login"

TENANT_ID=$(az account show --query tenantId --output tsv)
FQDN=$(az containerapp show --name "$APP" --resource-group "$RG" --query properties.configuration.ingress.fqdn --output tsv)
# The address Microsoft sends the browser back to after the login.
REDIRECT_URI="https://$FQDN/.auth/login/aad/callback"

echo "1/6 App registration $LOGIN_APP (redirect: $REDIRECT_URI)"
APP_ID=$(az ad app list --display-name "$LOGIN_APP" --query "[0].appId" --output tsv)
if [ -z "$APP_ID" ]; then
  # AzureADMyOrg = single tenant.
  APP_ID=$(az ad app create --display-name "$LOGIN_APP" --sign-in-audience AzureADMyOrg --query appId --output tsv)
fi
# ID tokens: Easy Auth asks for one at the login (the docs say it is required).
az ad app update --id "$APP_ID" --web-redirect-uris "$REDIRECT_URI" --enable-id-token-issuance true

echo "2/6 Service principal with assignment required"
SP_ID=$(az ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" --output tsv)
if [ -z "$SP_ID" ]; then
  SP_ID=$(az ad sp create --id "$APP_ID" --query id --output tsv)
fi
az ad sp update --id "$SP_ID" --set appRoleAssignmentRequired=true

echo "3/6 Assign my account"
USER_ID=$(az ad signed-in-user show --query id --output tsv)
ASSIGNED=$(az rest --method GET \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$SP_ID/appRoleAssignedTo" \
  --query "length(value[?principalId=='$USER_ID'])" --output tsv)
if [ "$ASSIGNED" = "0" ]; then
  # appRoleId 0000... = "Default Access": the app has no own roles, the
  # assignment only says "this person may sign in".
  az rest --method POST \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$SP_ID/appRoleAssignedTo" \
    --headers "Content-Type=application/json" \
    --body "{\"principalId\":\"$USER_ID\",\"resourceId\":\"$SP_ID\",\"appRoleId\":\"00000000-0000-0000-0000-000000000000\"}" \
    --output none
fi

echo "4/6 New client secret (1 year) into the container app"
# Without --append, this deletes the old secrets of the registration.
SECRET=$(az ad app credential reset --id "$APP_ID" --display-name easy-auth --years 1 --query password --output tsv)
# Stored as the app secret "microsoft-provider-authentication-secret".
az containerapp auth microsoft update --name "$APP" --resource-group "$RG" \
  --client-id "$APP_ID" --client-secret "$SECRET" \
  --issuer "https://login.microsoftonline.com/$TENANT_ID/v2.0" \
  --yes --output none
unset SECRET

echo "5/6 Turn on the login for every request"
az containerapp auth update --name "$APP" --resource-group "$RG" \
  --enabled true \
  --unauthenticated-client-action RedirectToLoginPage \
  --redirect-provider azureactivedirectory \
  --require-https true \
  --yes --output none
# (Show it with a separate command: the output of "auth update" has another
# shape, and the same query printed nothing on the first run, 2026-11-17.)
az containerapp auth show --name "$APP" --resource-group "$RG" \
  --query "{enabled:platform.enabled, action:globalValidation.unauthenticatedClientAction}" --output table

echo "6/6 Remove the IP rule only-me from infra/05-aca.sh"
# The login checks who I am, so the rule about where I come from can go
# (my dynamic IP locked me out twice). Without rules, every IP reaches the
# login page, and only my account gets past it.
if [ -n "$(az containerapp ingress access-restriction list --name "$APP" --resource-group "$RG" --query "[?name=='only-me'].name" --output tsv)" ]; then
  az containerapp ingress access-restriction remove --name "$APP" --resource-group "$RG" --rule-name only-me --output none
fi

# Check: a private browser window on https://$FQDN asks for a Microsoft login;
#   curl -s -o /dev/null -w "%{http_code}" https://$FQDN/health  -> 401 (a script gets 401,
#   a browser gets 302 to the login page)
# Undo only this step:
#   az containerapp auth update --name "$APP" --resource-group "$RG" --enabled false
#   az ad app delete --id "$APP_ID"
