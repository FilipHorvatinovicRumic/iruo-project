# TechSprint Azure deployment

Single-run Azure deployment for the IRUO project.

## Input

`users.csv` uses `;` as delimiter and supports `developer` and `devops_lead` roles.

## Run

```powershell
./deploy.ps1 -CsvPath ./users.csv
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
