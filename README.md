# TechSprint Azure Deployment FINAL_v10

This package implements the required multi-region architecture while accounting for the Azure for Students 6-vCPU-per-region limit.

## Architecture

- France Central: one public Jump Host VM and one separate private DevOps Lead VM.
- Two developers: one resource group and one distinct allowed region per developer.
- Each developer gets two Moodle VMs. Every selected VM SKU has exactly 2 vCPUs and at least 4 GiB RAM.
- Only the Jump Host has a public IP.
- Hub/spoke connectivity uses Global VNet Peering with forwarded traffic enabled.
- Each developer receives a VNet, NSG/ASG, internal Standard Load Balancer, Blob Storage, Azure Files NFS storage, and two VMs with OS and data disks.
- CSV-driven IAM/RBAC limits developers to VM power operations in their own resource group; the lead receives that role across all project resource groups.

## Capacity selection

The deployment does not validate a large hard-coded SKU list one item at a time. It instead:

1. Calls `az vm list-skus` once for each allowed region and removes subscription-restricted, non-x64, and non-compliant VM sizes.
2. Calls `az vm list-usage` once for each region and checks both total regional and VM-family vCPU quota.
3. Ranks inexpensive general-purpose sizes and keeps at most three candidates per region by default.
4. Creates a developer network only after the region has passed these checks.
5. Performs a real deployment attempt because Azure does not expose guaranteed live physical capacity. On a genuine Compute allocation failure it tries the next shortlisted SKU, then another eligible region.

Failures from non-Compute resources are reported immediately instead of being mislabeled as VM capacity failures. A failed-region resource group is deleted only when it has the expected `project=techsprint` and `environment=testing` tags.

## Inspect the plan without changing anything

```powershell
./deploy.ps1 -CsvPath ./users.csv -PlanOnly
```

This reads subscription SKU/quota information but does not accept Marketplace terms, create resources or identities, or write local secrets.

## Deploy

```powershell
./deploy.ps1 -CsvPath ./users.csv
```

Optional region and retry configuration:

```powershell
./deploy.ps1 -CsvPath ./users.csv `
  -HubLocation francecentral `
  -DeveloperRegionPool germanywestcentral,polandcentral,switzerlandnorth,spaincentral `
  -MaxSkuAttemptsPerRegion 3
```

The script is safe to rerun. Existing complete VM pairs are reused, while Bicep reconciles the rest of the named TechSprint resources.

## Verify

```powershell
./verify.ps1
```

## Cleanup

```powershell
./cleanup.ps1
```

## Rocky Linux Marketplace image

All VMs use `resf:rockylinux-x86_64:9-base:latest`. The templates include the required Marketplace `plan` metadata, and the deployment accepts its terms once per subscription. If an old named TechSprint VM lacks the required plan, the script removes only that incompatible VM object and recreates it; other project resources remain intact.
