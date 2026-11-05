#!/usr/bin/env bash
# Step 0: one resource group that holds everything for CalmOps.
# Run with Git Bash after `az login`.
set -euo pipefail

RG="rg-calmops"
LOCATION="germanywestcentral"   # EU region, because the data is personal
TAGS="project=calmops"

az group create \
  --name "$RG" \
  --location "$LOCATION" \
  --tags $TAGS \
  --output table

# Budget alert (about 20 EUR/month, email at 80 %) is created in the portal:
# Cost Management -> Budgets -> scope rg-calmops.

# Delete everything again (all resources inside the group, cannot be undone):
#   az group delete --name "$RG" --yes --no-wait
