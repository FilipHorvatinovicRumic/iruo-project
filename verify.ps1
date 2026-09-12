$ErrorActionPreference = "Stop"
$summary = Get-Content (Join-Path $PSScriptRoot "deployment-summary.json") -Raw | ConvertFrom-Json
Write-Host "=== RESOURCE GROUPS ===" -ForegroundColor Cyan
az group list --query "[?tags.project=='techsprint' && tags.environment=='testing'].{Name:name,Location:location}" -o table
Write-Host "`n=== VIRTUAL MACHINES ===" -ForegroundColor Cyan
az vm list -d --query "[?tags.project=='techsprint'].{VM:name,RG:resourceGroup,Power:powerState,Private:privateIps,Public:publicIps,Size:hardwareProfile.vmSize,Location:location}" -o table
Write-Host "`n=== PUBLIC IP ADDRESSES (ONLY JUMP EXPECTED) ===" -ForegroundColor Cyan
az network public-ip list --query "[?tags.project=='techsprint'].{Name:name,RG:resourceGroup,IP:ipAddress,Location:location}" -o table
Write-Host "`n=== LOAD BALANCERS ===" -ForegroundColor Cyan
az network lb list --query "[?tags.project=='techsprint'].{Name:name,RG:resourceGroup,SKU:sku.name,Frontend:frontendIPConfigurations[0].privateIPAddress,Location:location}" -o table
Write-Host "`n=== STORAGE ACCOUNTS ===" -ForegroundColor Cyan
az storage account list --query "[?tags.project=='techsprint'].{Name:name,RG:resourceGroup,Kind:kind,SKU:sku.name,SharedKey:allowSharedKeyAccess,Location:location}" -o table
Write-Host "`n=== GLOBAL PEERINGS ===" -ForegroundColor Cyan
foreach ($rg in @($summary.HubResourceGroup) + @($summary.Developers.ResourceGroup)) {
    $vnets = az network vnet list -g $rg --query "[].name" -o tsv
    foreach ($vnet in $vnets) { az network vnet peering list -g $rg --vnet-name $vnet --query "[].{VNet:'$vnet',Peering:name,State:peeringState,Forwarded:allowForwardedTraffic,Remote:remoteVirtualNetwork.id}" -o table }
}
Write-Host "`n=== RBAC ===" -ForegroundColor Cyan
az role assignment list --all --query "[?roleDefinitionName=='TechSprint VM Power Operator'].{Principal:principalName,Type:principalType,Scope:scope}" -o table
Write-Host "`n=== TAG COVERAGE ===" -ForegroundColor Cyan
az resource list --tag project=techsprint --query "[].{Name:name,Type:type,RG:resourceGroup,Environment:tags.environment,Location:location}" -o table
Write-Host "`n=== ACCESS ===" -ForegroundColor Cyan
Write-Host "SSH to jump: ssh -i ~/.ssh/techsprint_azure azureadmin@$($summary.JumpPublicIp)"
Write-Host "Lead private IP: $($summary.LeadPrivateIp)"
foreach($d in $summary.Developers){Write-Host "$($d.Name): region=$($d.Location), internal LB=$($d.LoadBalancerIp), VMs=$($d.VMs -join ', ')"}
