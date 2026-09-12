# TechSprint Azure deployment

Single-run Azure deployment for the IRUO project.

## Input

`users.csv` uses `;` as delimiter and supports `developer` and `devops_lead` roles.

## Run

```powershell
./deploy.ps1 -CsvPath ./users.csv -Location francecentral
```

The script creates a hub resource group, one resource group and isolated VNet per developer, a public jump host, a private DevOps Lead VM, two private Moodle VMs per developer, internal Standard Load Balancers, NSGs and ASGs, OS plus data disks, Blob Storage with Managed Identity access, Azure Files NFS backup storage, hub/spoke peering, a custom VM power role, and CSV-driven identities.

Because the Azure for Students subscription used for the project has a six-vCPU regional quota, the demonstrational deployment uses one-vCPU VM SKUs. The target design remains two vCPU and four GB RAM per Moodle VM.

If Microsoft Entra user creation is blocked by tenant directory permissions, `deploy.ps1` automatically creates user-assigned managed identities as an RBAC demonstration fallback and records that condition in `deployment-summary.json`.

## Verify

```powershell
./verify.ps1
```

## Cleanup

```powershell
./cleanup.ps1
```


## Azure for Students region handling

The tested subscription is restricted by Azure Policy to a small allow-list of regions. This package defaults to `francecentral`. If an older interrupted run left a TechSprint resource group in another region, `deploy.ps1` detects that project-specific stale resource group, deletes it, waits for deletion, and recreates it in the requested region.

## VM SKU capacity fallback

Azure for Students can return `SkuNotAvailable` even for a size that exists in the selected region. The deployment therefore retries a controlled list of one-vCPU SKUs. Hub VMs prefer B-series sizes; Moodle VMs prefer D/DS v2 sizes to remain as close as possible to the requested memory specification. The actual selected SKU is written to `deployment-summary.json`.
