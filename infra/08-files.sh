#!/usr/bin/env bash
# Step 8: check-ins survive a restart. An Azure Files share is mounted at
# /data, where the app keeps its files (CALMOPS_DATA_DIR=/data, Dockerfile).
# Run with Git Bash after `az login`, after infra/05-aca.sh:
#   & "C:\Program Files\Git\bin\bash.exe" infra/08-files.sh
#
# What it builds:
#   1. A storage account stcalmopsts = the storage room (name is global).
#   2. A file share calmops-data in it = the network drive, 1 GiB, SMB.
#   3. Environment storage calmops-data in cae-calmops = the environment
#      learns how to open the drive. It opens it with the storage account
#      key: the key is read here, handed straight to the environment and never
#      printed. (Opening it with a managed identity is still preview in
#      2026-11, so step 8 uses the key; a rerun hands over the current key.)
#   4. A volume "data" in the app, mounted at /data. This changes the app's
#      template, so Container Apps makes a new revision (step 7 was app-level).
# Safe to run again: parts 1, 2 and 4 check first; part 3 just sets it again.
set -euo pipefail

# Git Bash turns "/subscriptions/..." into a Windows path. This stops that.
export MSYS_NO_PATHCONV=1

RG="rg-calmops"
LOCATION="germanywestcentral"
ENV_NAME="cae-calmops"
APP="ca-calmops"
ACCOUNT="stcalmopsts"
SHARE="calmops-data"
ENV_STORAGE="calmops-data"
VOLUME="data"

echo "1/5 Storage account $ACCOUNT"
if ! az storage account show --name "$ACCOUNT" --resource-group "$RG" --output none 2>/dev/null; then
  # Standard_LRS: 3 copies in one data center, the cheapest. StorageV2: the normal kind.
  az storage account create --name "$ACCOUNT" --resource-group "$RG" --location "$LOCATION" \
    --sku Standard_LRS --kind StorageV2 \
    --min-tls-version TLS1_2 --https-only true --allow-blob-public-access false \
    --tags project=calmops --output none
fi

echo "2/5 File share $SHARE (1 GiB, SMB)"
if [ "$(az storage share-rm exists --resource-group "$RG" --storage-account "$ACCOUNT" --name "$SHARE" --query exists --output tsv)" != "true" ]; then
  # share-rm = made through Azure Resource Manager (my az login), no key needed.
  az storage share-rm create --resource-group "$RG" --storage-account "$ACCOUNT" --name "$SHARE" \
    --quota 1 --enabled-protocols SMB --output none
fi

echo "3/5 Environment storage $ENV_STORAGE in $ENV_NAME (with the account key)"
KEY=$(az storage account keys list --account-name "$ACCOUNT" --resource-group "$RG" --query "[0].value" --output tsv)
az containerapp env storage set --name "$ENV_NAME" --resource-group "$RG" \
  --storage-name "$ENV_STORAGE" \
  --azure-file-account-name "$ACCOUNT" --azure-file-account-key "$KEY" \
  --azure-file-share-name "$SHARE" --access-mode ReadWrite --output none
unset KEY

echo "4/5 Volume $VOLUME at /data in $APP (new revision)"
if [ -z "$(az containerapp show --name "$APP" --resource-group "$RG" --query "properties.template.volumes[?name=='$VOLUME'].name" --output tsv)" ]; then
  # The CLI has no --volume flag. The Learn tutorial exports the app as YAML,
  # adds the volume by hand and runs `az containerapp update --yaml`. This does
  # the same in one go: take the app's template as it is (image, env, scale
  # with max 1 replica), add the volume and the mount, send the template back.
  # uid/gid 1000 = the user calmops in the Dockerfile. An SMB share has no Linux
  # owners, so the mount says who owns the files; without it the app may not
  # be allowed to write. 0750/0640 = only that user writes.
  TEMPLATE=$(az containerapp show --name "$APP" --resource-group "$RG" --query "merge(properties.template, {
      volumes: [{name: '$VOLUME', storageType: 'AzureFile', storageName: '$ENV_STORAGE',
                 mountOptions: 'uid=1000,gid=1000,dir_mode=0750,file_mode=0640'}],
      containers: [merge(properties.template.containers[0], {volumeMounts: [{volumeName: '$VOLUME', mountPath: '/data'}]})]
    })" --output json | tr -d '\n')
  APP_ID=$(az containerapp show --name "$APP" --resource-group "$RG" --query id --output tsv)
  # PATCH = change only what is sent (the template); ingress, identity,
  # registry, secrets and the login stay as they are.
  az rest --method PATCH --uri "https://management.azure.com$APP_ID?api-version=2025-07-01" \
    --headers "Content-Type=application/json" \
    --body "{\"properties\":{\"template\":$TEMPLATE}}" --output none
  # The PATCH only says "accepted"; the new revision is built afterwards.
  # Wait for it, else part 5 shows the old one (first run, 2026-11-17).
  until [ -n "$(az containerapp show --name "$APP" --resource-group "$RG" --query "properties.template.volumes[?name=='$VOLUME'].name" --output tsv)" ] &&
        [ "$(az containerapp show --name "$APP" --resource-group "$RG" --query properties.provisioningState --output tsv)" = "Succeeded" ]; do
    sleep 10
  done
fi

echo "5/5 Result"
az containerapp show --name "$APP" --resource-group "$RG" \
  --query "{revision:properties.latestRevisionName, volume:properties.template.volumes[0].storageName, mountPath:properties.template.containers[0].volumeMounts[0].mountPath, maxReplicas:properties.template.scale.maxReplicas}" \
  --output table

# Check: the app seeds measures.csv into /data at its first start, so after
# one request (cold start can take ~2 min) the share holds it:
#   az storage file list --account-name stcalmopsts --share-name calmops-data --output table
# Then: save a check-in, restart (az containerapp revision restart), the check-in is still there.
# Undo only this step (the files on the share are deleted with the account):
#   remove the volume from the app (YAML or PATCH), then
#   az containerapp env storage remove --name cae-calmops --resource-group rg-calmops --storage-name calmops-data --yes
#   az storage account delete --name stcalmopsts --resource-group rg-calmops --yes
