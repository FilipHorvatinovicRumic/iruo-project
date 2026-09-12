$ErrorActionPreference = "Stop"
$groups = az group list --query "[?tags.project=='techsprint' && tags.environment=='testing'].name" -o tsv
foreach ($group in $groups) {
    Write-Host "Deleting $group"
    az group delete --name $group --yes --no-wait
}
