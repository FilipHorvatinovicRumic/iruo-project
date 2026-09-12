param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,
    [string]$HubLocation = "francecentral",
    [string[]]$DeveloperRegionPool = @("germanywestcentral", "polandcentral", "switzerlandnorth", "spaincentral"),
    [string]$AdminUsername = "azureadmin",
    [ValidateRange(1, 10)]
    [int]$MaxSkuAttemptsPerRegion = 3,
    [switch]$UseObservedCapacity,
    [switch]$PlanOnly
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Invoke-AzCli {
    $output = & az @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
    return $output
}

function Get-DeploymentFailure {
    param([string]$ResourceGroup, [string]$DeploymentName, [string]$TopLevelMessage)

    $failedOperations = @()
    $operationJson = & az deployment operation group list --resource-group $ResourceGroup --name $DeploymentName --query "[?properties.provisioningState=='Failed'].{Resource:properties.targetResource.resourceName,Type:properties.targetResource.resourceType,Code:properties.statusMessage.error.code,Message:properties.statusMessage.error.message}" --only-show-errors -o json 2>$null
    if ($LASTEXITCODE -eq 0 -and $operationJson) {
        $failedOperations = @(($operationJson -join "`n") | ConvertFrom-Json)
    }

    $details = @($failedOperations | ForEach-Object { "[$($_.Type)/$($_.Resource)] $($_.Code): $($_.Message)" })
    $text = @($TopLevelMessage, $details) | Where-Object { $_ } | Join-String -Separator "`n"
    return [pscustomobject]@{ Text = $text; Operations = $failedOperations }
}

function Test-ComputeCapacityFailure {
    param([pscustomobject]$Failure)

    $capacityPattern = 'SkuNotAvailable|AllocationFailed|ZonalAllocationFailed|OverconstrainedAllocationRequest|NotAvailableForSubscription|OperationNotAllowed.*(vCPU|core)|quota.*(vCPU|core)|provided for the VM size is not valid'
    $computeOperation = @($Failure.Operations | Where-Object { $_.Type -eq 'Microsoft.Compute/virtualMachines' }).Count -gt 0
    $computeText = $Failure.Text -match 'Microsoft.Compute/virtualMachines|virtual machine|VM size|vCPU'
    return (($computeOperation -or $computeText) -and $Failure.Text -match $capacityPattern)
}

function Get-SkuCapability {
    param([object]$Sku, [string]$Name)
    $capability = @($Sku.capabilities | Where-Object { $_.name -eq $Name } | Select-Object -First 1)
    if ($capability.Count -eq 0) { return $null }
    return $capability[0].value
}

$script:regionInventoryCache = @{}
$script:preferredSkus = @(
    'Standard_B2ls_v2', 'Standard_B2als_v2', 'Standard_B2s', 'Standard_B2s_v2', 'Standard_B2as_v2',
    'Standard_D2as_v5', 'Standard_D2s_v5', 'Standard_D2s_v4', 'Standard_D2as_v4', 'Standard_D2s_v3',
    'Standard_A2_v2', 'Standard_F2s_v2'
)

function Get-RegionComputeInventory {
    param([Parameter(Mandatory = $true)][string]$Location)

    $key = $Location.ToLowerInvariant()
    if ($script:regionInventoryCache.ContainsKey($key)) { return $script:regionInventoryCache[$key] }

    Write-Host "Inspecting VM SKUs and quota in $Location..." -ForegroundColor DarkCyan
    $skuJson = Invoke-AzCli vm list-skus --location $Location --resource-type virtualMachines --all --only-show-errors -o json
    $usageJson = Invoke-AzCli vm list-usage --location $Location --only-show-errors -o json
    $inventory = [pscustomobject]@{
        Location = $Location
        Skus = @(($skuJson -join "`n") | ConvertFrom-Json)
        Usage = @(($usageJson -join "`n") | ConvertFrom-Json)
    }
    $script:regionInventoryCache[$key] = $inventory
    return $inventory
}

function Get-EligibleSkuPlan {
    param(
        [Parameter(Mandatory = $true)][string]$Location,
        [ValidateRange(0, 2)][int]$VmCount = 2,
        [string[]]$PreferSku = @()
    )

    $inventory = Get-RegionComputeInventory -Location $Location
    $requiredCores = 2 * $VmCount
    $totalUsage = @($inventory.Usage | Where-Object { $_.name.value -eq 'cores' -or $_.name.localizedValue -eq 'Total Regional vCPUs' } | Select-Object -First 1)
    if ($requiredCores -gt 0 -and $totalUsage.Count -gt 0) {
        $regionalFree = [int]$totalUsage[0].limit - [int]$totalUsage[0].currentValue
        if ($regionalFree -lt $requiredCores) {
            return [pscustomobject]@{ Location=$Location; Candidates=@(); Reason="regional vCPU quota has $regionalFree free; $requiredCores required" }
        }
    }

    $candidates = foreach ($sku in $inventory.Skus) {
        if ($sku.resourceType -ne 'virtualMachines' -or @($sku.restrictions).Count -gt 0) { continue }
        if ($sku.name -notmatch '^Standard_(B|D|DS|A|F|E)\d') { continue }

        $vcpus = Get-SkuCapability -Sku $sku -Name 'vCPUs'
        $availableVcpus = Get-SkuCapability -Sku $sku -Name 'vCPUsAvailable'
        $memory = Get-SkuCapability -Sku $sku -Name 'MemoryGB'
        $architecture = Get-SkuCapability -Sku $sku -Name 'CpuArchitectureType'
        if ($null -eq $vcpus -or [int]$vcpus -ne 2) { continue }
        if ($availableVcpus -and [int]$availableVcpus -ne 2) { continue }
        if ($null -eq $memory -or [double]$memory -lt 4 -or [double]$memory -gt 16) { continue }
        if ($architecture -and $architecture -ne 'x64') { continue }

        $familyUsage = @($inventory.Usage | Where-Object { $_.name.value -eq $sku.family } | Select-Object -First 1)
        if ($requiredCores -gt 0 -and $familyUsage.Count -gt 0) {
            $familyFree = [int]$familyUsage[0].limit - [int]$familyUsage[0].currentValue
            if ($familyFree -lt $requiredCores) { continue }
        }

        $preferenceIndex = [array]::IndexOf($script:preferredSkus, [string]$sku.name)
        if ($preferenceIndex -lt 0) { $preferenceIndex = 100 }
        $explicitIndex = [array]::IndexOf($PreferSku, [string]$sku.name)
        $score = if ($explicitIndex -ge 0) { $explicitIndex - 1000 } else { $preferenceIndex }
        [pscustomobject]@{ Name=[string]$sku.name; Family=[string]$sku.family; MemoryGB=[double]$memory; Score=$score }
    }

    $ranked = @($candidates | Sort-Object Score, MemoryGB, Name | Select-Object -First $MaxSkuAttemptsPerRegion)
    $reason = if ($ranked.Count) { 'eligible' } else { 'no unrestricted 2-vCPU x64 SKU with >=4 GiB and sufficient family quota' }
    return [pscustomobject]@{ Location=$Location; Candidates=$ranked; Reason=$reason }
}

function Deploy-HubWithSkuFallback {
    param(
        [string]$ResourceGroup,[string]$TemplateFile,[string]$AdminUsername,[string]$SshPublicKey,[string]$Location,
        [object[]]$Candidates,[string]$ExistingJumpSku,[string]$ExistingLeadSku
    )
    foreach ($candidate in $Candidates) {
        $sku = $candidate.Name
        $jumpSku = if ($ExistingJumpSku) { $ExistingJumpSku } else { $sku }
        $leadSku = if ($ExistingLeadSku) { $ExistingLeadSku } else { $sku }
        Write-Host "Allocating missing hub VM(s) in $Location (Jump=$jumpSku, Lead=$leadSku)..." -ForegroundColor DarkCyan
        $output = & az deployment group create --resource-group $ResourceGroup --name 'techsprint-hub' --template-file $TemplateFile --parameters adminUsername=$AdminUsername sshPublicKey=$SshPublicKey location=$Location jumpVmSize=$jumpSku leadVmSize=$leadSku --only-show-errors -o json 2>&1
        if ($LASTEXITCODE -eq 0) {
            $selected = if ($jumpSku -eq $leadSku) { $jumpSku } else { "Jump=$jumpSku; Lead=$leadSku" }
            return [pscustomobject]@{ Result=(($output -join "`n") | ConvertFrom-Json); Sku=$selected }
        }
        $failure = Get-DeploymentFailure -ResourceGroup $ResourceGroup -DeploymentName 'techsprint-hub' -TopLevelMessage ($output -join "`n")
        if (Test-ComputeCapacityFailure -Failure $failure) {
            Write-Warning "Compute allocation failed for hub SKU $sku. Azure said: $($failure.Text)"
            continue
        }
        throw $failure.Text
    }
    throw "None of the quota-eligible hub SKUs could allocate in $Location."
}

function Deploy-WorkloadWithSkuFallback {
    param(
        [string]$ResourceGroup,[string]$DeploymentName,[string]$TemplateFile,
        [string]$DeveloperSlug,[string]$DeveloperDisplayName,[string]$VnetName,[string]$SubnetName,[string]$AsgName,
        [string]$LoadBalancerIp,[string]$AdminUsername,[string]$SshPublicKey,[string]$BlobStorageName,[string]$FileStorageName,
        [string]$Location,[object[]]$Candidates
    )
    foreach ($candidate in $Candidates) {
        $sku = $candidate.Name
        Write-Host "Allocating two Moodle VMs with $sku in $Location..." -ForegroundColor DarkCyan
        $output = & az deployment group create --resource-group $ResourceGroup --name $DeploymentName --template-file $TemplateFile --parameters developerSlug=$DeveloperSlug developerDisplayName="$DeveloperDisplayName" vnetName=$VnetName subnetName=$SubnetName asgName=$AsgName loadBalancerIp=$LoadBalancerIp adminUsername=$AdminUsername sshPublicKey=$SshPublicKey blobStorageName=$BlobStorageName fileStorageName=$FileStorageName location=$Location appVmSize=$sku --only-show-errors -o json 2>&1
        if ($LASTEXITCODE -eq 0) {
            return [pscustomobject]@{ Result=(($output -join "`n")|ConvertFrom-Json); Sku=$sku }
        }
        $failure = Get-DeploymentFailure -ResourceGroup $ResourceGroup -DeploymentName $DeploymentName -TopLevelMessage ($output -join "`n")
        if (Test-ComputeCapacityFailure -Failure $failure) {
            Write-Warning "Compute allocation failed for $sku in $Location. Azure said: $($failure.Text)"
            continue
        }
        throw $failure.Text
    }
    return $null
}

function Ensure-ProjectResourceGroup {
    param([Parameter(Mandatory=$true)][string]$Name,[Parameter(Mandatory=$true)][string]$Location)
    $existingLocation = & az group show --name $Name --query location -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $existingLocation) {
        $existingLocation = $existingLocation.Trim().ToLowerInvariant()
        if ($existingLocation -ne $Location.ToLowerInvariant()) {
            Write-Warning "Resource group '$Name' exists in '$existingLocation', required '$Location'."
            Remove-TechSprintResourceGroup -Name $Name
        } else { return }
    }
    Invoke-AzCli group create --name $Name --location $Location --tags project=techsprint environment=testing -o none | Out-Null
}

function Remove-TechSprintResourceGroup {
    param([Parameter(Mandatory=$true)][string]$Name)

    $groupJson = & az group show --name $Name --only-show-errors -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $groupJson) { return }
    $group = ($groupJson -join "`n") | ConvertFrom-Json
    if ($group.tags.project -ne 'techsprint' -or $group.tags.environment -ne 'testing') {
        throw "Refusing to delete resource group '$Name' because it is not tagged project=techsprint and environment=testing."
    }

    Write-Warning "Deleting failed/stale TechSprint resource group '$Name'."
    Invoke-AzCli group delete --name $Name --yes --no-wait | Out-Null
    $deadline = (Get-Date).AddMinutes(15)
    do {
        Start-Sleep -Seconds 5
        $stillExists = (& az group exists --name $Name -o tsv 2>$null).Trim()
        if ((Get-Date) -gt $deadline) { throw "Timed out waiting for resource group '$Name' to be deleted." }
    } while ($stillExists -eq 'true')
}

function Remove-IncompatibleMarketplaceVm {
    param(
        [Parameter(Mandatory=$true)][string]$ResourceGroup,
        [Parameter(Mandatory=$true)][string[]]$VmNames
    )
    foreach ($vmName in $VmNames) {
        $vmJson = & az vm show --resource-group $ResourceGroup --name $vmName -o json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $vmJson) { continue }
        $vm = ($vmJson -join "`n") | ConvertFrom-Json
        $planName = if ($vm.plan) { [string]$vm.plan.name } else { '' }
        $planProduct = if ($vm.plan) { [string]$vm.plan.product } else { '' }
        $planPublisher = if ($vm.plan) { [string]$vm.plan.publisher } else { '' }
        $compatible = ($planName -eq '9-base' -and $planProduct -eq 'rockylinux-x86_64' -and $planPublisher -eq 'resf')
        if (-not $compatible) {
            Write-Warning "Existing VM '$vmName' in '$ResourceGroup' was created without the required Rocky Marketplace plan (or with an incompatible plan). Azure cannot add/change a Marketplace plan on an existing VM. Deleting only this stale TechSprint VM before recreation."
            Invoke-AzCli vm delete --resource-group $ResourceGroup --name $vmName --yes | Out-Null
            do {
                Start-Sleep -Seconds 3
                $exists = & az vm show --resource-group $ResourceGroup --name $vmName --query name -o tsv 2>$null
            } while ($LASTEXITCODE -eq 0 -and $exists)
        }
    }
}

function Convert-ToSlug {
    param([string]$Text)
    $normalized=$Text.Normalize([Text.NormalizationForm]::FormD)
    $chars=foreach($c in $normalized.ToCharArray()){if([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [Globalization.UnicodeCategory]::NonSpacingMark){$c}}
    return ((-join $chars).Normalize([Text.NormalizationForm]::FormC).ToLowerInvariant() -replace '[^a-z0-9]','')
}

function New-RandomPassword {
    $bytes=New-Object byte[] 18
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return "Ts!"+([Convert]::ToBase64String($bytes) -replace '[+/=]','A').Substring(0,20)+"9a"
}

function New-StorageName {
    param([string]$Slug,[string]$Suffix,[string]$Hash)
    $short=if($Slug.Length -gt 7){$Slug.Substring(0,7)}else{$Slug}
    return ("stts{0}{1}{2}" -f $short,$Hash,$Suffix).ToLowerInvariant()
}

function Ensure-RoleAssignment {
    param(
        [Parameter(Mandatory=$true)][string]$ObjectId,
        [Parameter(Mandatory=$true)][string]$Role,
        [Parameter(Mandatory=$true)][string]$Scope,
        [ValidateSet('User','Group','ServicePrincipal','ForeignGroup','Device')][string]$PrincipalType
    )

    $lastMessage = ''
    for ($attempt=1; $attempt -le 8; $attempt++) {
        $cliArgs = @('role','assignment','create','--assignee-object-id',$ObjectId,'--role',$Role,'--scope',$Scope,'--only-show-errors','-o','none')
        if ($PrincipalType) { $cliArgs += @('--assignee-principal-type',$PrincipalType) }
        $result = & az @cliArgs 2>&1
        if ($LASTEXITCODE -eq 0) { return }
        $lastMessage = $result -join "`n"
        if ($lastMessage -match 'RoleAssignmentExists') { return }
        if ($attempt -lt 8) { Start-Sleep -Seconds ([Math]::Min(30, 5 * $attempt)) }
    }
    throw "Role assignment '$Role' failed for principal $ObjectId at scope $Scope after 8 attempts:`n$lastMessage"
}

function Update-VmSshKey {
    param(
        [Parameter(Mandatory=$true)][string]$ResourceGroup,
        [Parameter(Mandatory=$true)][string]$VmName,
        [Parameter(Mandatory=$true)][string]$Username,
        [Parameter(Mandatory=$true)][string]$PublicKey
    )

    Write-Host "Refreshing SSH access on existing VM $VmName..." -ForegroundColor DarkCyan
    $result = & az vm user update --resource-group $ResourceGroup --name $VmName --username $Username --ssh-key-value $PublicKey --only-show-errors -o none 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not add the current Cloud Shell SSH key to existing VM '$VmName':`n$($result -join "`n")"
    }
}

function New-ReusedWorkloadResult {
    param(
        [string]$Vm1Name,[string]$Vm2Name,[string]$Vm1PrincipalId,[string]$Vm2PrincipalId,
        [string]$BlobStorageId,[string]$BlobStorageName,[string]$FileStorageName
    )
    return [pscustomobject]@{
        properties = [pscustomobject]@{
            outputs = [pscustomobject]@{
                vm1Name = [pscustomobject]@{value=$Vm1Name}
                vm2Name = [pscustomobject]@{value=$Vm2Name}
                vm1PrincipalId = [pscustomobject]@{value=$Vm1PrincipalId}
                vm2PrincipalId = [pscustomobject]@{value=$Vm2PrincipalId}
                blobStorageId = [pscustomobject]@{value=$BlobStorageId}
                blobStorageName = [pscustomobject]@{value=$BlobStorageName}
                fileStorageName = [pscustomobject]@{value=$FileStorageName}
            }
        }
    }
}

$scriptRoot=Split-Path -Parent $MyInvocation.MyCommand.Path
$csvFullPath=(Resolve-Path $CsvPath).Path
$users=Import-Csv -Path $csvFullPath -Delimiter ';'
$developers = @($users | Where-Object { $_.rola.Trim().ToLowerInvariant() -eq 'developer' })
$leads = @($users | Where-Object { $_.rola.Trim().ToLowerInvariant() -eq 'devops_lead' })
if($developers.Count -ne 2){throw "Za obavezni test projekta CSV mora sadržavati točno 2 developera."}
if($leads.Count -ne 1){throw "CSV mora sadržavati točno jednog devops_lead korisnika."}
if($DeveloperRegionPool.Count -lt $developers.Count){throw "DeveloperRegionPool mora sadržavati najmanje dvije dozvoljene Azure regije."}
$DeveloperRegionPool = @($DeveloperRegionPool | Where-Object { $_.ToLowerInvariant() -ne $HubLocation.ToLowerInvariant() } | Select-Object -Unique)
if($DeveloperRegionPool.Count -lt $developers.Count){throw "Potrebne su najmanje dvije developer regije različite od hub regije zbog 6-vCPU regionalne kvote."}

$account=Invoke-AzCli account show -o json|ConvertFrom-Json
$subscriptionId=$account.id
$tenantId=$account.tenantId
$hashSource=[Text.Encoding]::UTF8.GetBytes($subscriptionId)
$sha=[Security.Cryptography.SHA256]::Create().ComputeHash($hashSource)
$hash=([BitConverter]::ToString($sha).Replace('-','').ToLowerInvariant()).Substring(0,4)
$hubRg="rg-ts-hub-test"
$sshDir=Join-Path $HOME ".ssh"
$sshKeyPath=Join-Path $sshDir "techsprint_azure"
$secretDir=Join-Path $scriptRoot ".secrets"
$secretFile=Join-Path $secretDir "entra-users.txt"

Write-Host "=== TechSprint Azure deployment ===" -ForegroundColor Cyan
Write-Host "Package: FINAL_v13 - immutable-safe reuse + cached-capacity fast path" -ForegroundColor Green
Write-Host "Subscription: $($account.name)"
Write-Host "Hub: $HubLocation -> Jump VM + separate DevOps Lead VM"
Write-Host "Developer regions will be selected automatically from: $($DeveloperRegionPool -join ' , ')"
Write-Host "Each developer remains in a separate region and gets 2 Moodle VMs (2 vCPU / >=4 GiB each)."
if ($PlanOnly) {
    Write-Host "Bicep: not required in plan-only mode"
} else {
    $bicepVersion = & az bicep version 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Bicep CLI is missing; installing it with Azure CLI..." -ForegroundColor Yellow
        Invoke-AzCli bicep install | Out-Null
        $bicepVersion = Invoke-AzCli bicep version
    }
    Write-Host "Bicep: $($bicepVersion -join ' ')"
}

Write-Host "`n[PLAN] Resolving developer capacity before creating resources..." -ForegroundColor Cyan
$developerRegionPlans = @{}
if ($UseObservedCapacity) {
    Write-Host "Using the supplied capacity snapshot; live regional SKU/quota scans are skipped." -ForegroundColor Yellow
    $observedSwissCandidates = @(
        [pscustomobject]@{Name='Standard_B2ls_v2';Family='observed';MemoryGB=4;Score=0},
        [pscustomobject]@{Name='Standard_B2als_v2';Family='observed';MemoryGB=4;Score=1},
        [pscustomobject]@{Name='Standard_B2s_v2';Family='observed';MemoryGB=8;Score=2}
    ) | Select-Object -First $MaxSkuAttemptsPerRegion
    foreach ($location in $DeveloperRegionPool) {
        $candidates = if ($location -eq 'switzerlandnorth') { @($observedSwissCandidates) } else { @() }
        $reason = if ($location -eq 'polandcentral') { 'observed regional quota has only 2 free vCPUs; 4 required' } else { 'observed as having no eligible unrestricted SKU/family quota' }
        $developerRegionPlans[$location.ToLowerInvariant()] = [pscustomobject]@{Location=$location;Candidates=$candidates;Reason=$reason}
    }
    Write-Host "  switzerlandnorth: Standard_B2ls_v2 (4 GiB), Standard_B2als_v2 (4 GiB), Standard_B2s_v2 (8 GiB)" -ForegroundColor Green
    Write-Host "  germanywestcentral, polandcentral, spaincentral: skipped from supplied results" -ForegroundColor DarkGray
} else {
    foreach ($location in $DeveloperRegionPool) {
        $plan = Get-EligibleSkuPlan -Location $location -VmCount 2
        $developerRegionPlans[$location.ToLowerInvariant()] = $plan
        if ($plan.Candidates.Count -gt 0) {
            $candidateText = @($plan.Candidates | ForEach-Object { "$($_.Name) ($($_.MemoryGB) GiB)" }) -join ', '
            Write-Host "  $location`: $candidateText" -ForegroundColor Green
        } else {
            Write-Warning "$location skipped: $($plan.Reason)."
        }
    }
}
$existingDeveloperPlacements = @{}
foreach ($developer in $developers) {
    $slug = Convert-ToSlug "$($developer.ime)$($developer.prezime)"
    $expectedNames = @("vm-ts-$slug-app01", "vm-ts-$slug-app02")
    $vmJson = & az vm list -g "rg-ts-$slug-test" --only-show-errors -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $vmJson) { continue }
    $compatible = @(($vmJson -join "`n") | ConvertFrom-Json | Where-Object {
        $_.name -in $expectedNames -and $_.plan.name -eq '9-base' -and $_.plan.product -eq 'rockylinux-x86_64' -and $_.plan.publisher -eq 'resf'
    })
    $locations = @($compatible.location | Where-Object { $_ -in $DeveloperRegionPool } | Select-Object -Unique)
    $sizes = @($compatible.hardwareProfile.vmSize | Where-Object { $_ } | Select-Object -Unique)
    if ($compatible.Count -eq 2 -and $locations.Count -eq 1 -and $sizes.Count -eq 1) {
        $existingDeveloperPlacements[$slug] = [pscustomobject]@{ Location=$locations[0]; Sku=$sizes[0] }
    }
}

Write-Host "`n[PLAN] Proposed developer placement:" -ForegroundColor Cyan
$plannedDeveloperAssignments = @()
$plannedRegions = @()
for ($index=1; $index -le $developers.Count; $index++) {
    $developer = $developers[$index-1]
    $slug = Convert-ToSlug "$($developer.ime)$($developer.prezime)"
    $displayName = "$($developer.ime) $($developer.prezime)"
    $regionOrder = @()
    if ($existingDeveloperPlacements.ContainsKey($slug)) { $regionOrder += $existingDeveloperPlacements[$slug].Location }
    for ($offset=0; $offset -lt $DeveloperRegionPool.Count; $offset++) {
        $regionOrder += $DeveloperRegionPool[(($index-1+$offset) % $DeveloperRegionPool.Count)]
    }
    $selected = $null
    foreach ($location in @($regionOrder | Select-Object -Unique)) {
        if ($location -in $plannedRegions) { continue }
        if ($existingDeveloperPlacements.ContainsKey($slug) -and $existingDeveloperPlacements[$slug].Location -eq $location) {
            $selected = [pscustomobject]@{ Name=$displayName; Location=$location; Sku=$existingDeveloperPlacements[$slug].Sku; Mode='reuse existing pair' }
            break
        }
        $regionPlan = $developerRegionPlans[$location.ToLowerInvariant()]
        if ($regionPlan.Candidates.Count -gt 0) {
            $selected = [pscustomobject]@{ Name=$displayName; Location=$location; Sku=$regionPlan.Candidates[0].Name; Mode='new deployment' }
            break
        }
    }
    if (-not $selected) { throw "No valid distinct-region placement exists for $displayName. No resources were changed." }
    $plannedDeveloperAssignments += $selected
    $plannedRegions += $selected.Location
    Write-Host "  $($selected.Name) -> $($selected.Location) / $($selected.Sku) [$($selected.Mode)]" -ForegroundColor Green
}

$jumpJson = & az vm show -g $hubRg -n 'vm-ts-jump-test' --only-show-errors -o json 2>$null
$jumpVm = if ($LASTEXITCODE -eq 0 -and $jumpJson) { ($jumpJson -join "`n") | ConvertFrom-Json } else { $null }
$leadJson = & az vm show -g $hubRg -n 'vm-ts-lead-test' --only-show-errors -o json 2>$null
$leadVm = if ($LASTEXITCODE -eq 0 -and $leadJson) { ($leadJson -join "`n") | ConvertFrom-Json } else { $null }
$jumpExists = [bool]($jumpVm -and $jumpVm.plan.name -eq '9-base' -and $jumpVm.plan.product -eq 'rockylinux-x86_64' -and $jumpVm.plan.publisher -eq 'resf')
$leadExists = [bool]($leadVm -and $leadVm.plan.name -eq '9-base' -and $leadVm.plan.product -eq 'rockylinux-x86_64' -and $leadVm.plan.publisher -eq 'resf')
$existingJumpSku = if ($jumpExists) { [string]$jumpVm.hardwareProfile.vmSize } else { '' }
$existingLeadSku = if ($leadExists) { [string]$leadVm.hardwareProfile.vmSize } else { '' }
$hubPlan = $null
if ($jumpExists -and $leadExists) {
    Write-Host "  $HubLocation hub: existing Jump and Lead VMs will be reused." -ForegroundColor Green
} else {
    $existingHubCount = ([int]$jumpExists) + ([int]$leadExists)
    $existingHubSkus = @(@($existingJumpSku, $existingLeadSku) | Where-Object { $_ } | Select-Object -Unique)
    $hubPlan = Get-EligibleSkuPlan -Location $HubLocation -VmCount (2 - $existingHubCount) -PreferSku $existingHubSkus
    if ($hubPlan.Candidates.Count -eq 0) { throw "Hub region $HubLocation cannot host the missing hub VM(s): $($hubPlan.Reason)." }
    Write-Host "  $HubLocation hub candidates: $(@($hubPlan.Candidates.Name) -join ', ')" -ForegroundColor Green
}

if ($PlanOnly) {
    Write-Host "`nPLAN ONLY: no Azure resources, Marketplace terms, identities, or local secrets were changed." -ForegroundColor Yellow
    return
}

$defaultDomain=""
try{$defaultDomain=(Invoke-AzCli rest --method GET --url "https://graph.microsoft.com/v1.0/domains" --query "value[?isDefault].id | [0]" -o tsv).Trim()}catch{Write-Warning "Default Entra domain could not be read; IAM fallback remains available."}
New-Item -ItemType Directory -Force -Path $sshDir,$secretDir|Out-Null
if (-not (Test-Path $sshKeyPath)){& ssh-keygen -t ed25519 -f $sshKeyPath -N "" -C "techsprint-project"|Out-Null;if($LASTEXITCODE -ne 0){throw "SSH key generation failed."}}
$sshPublicKey=(Get-Content "$sshKeyPath.pub" -Raw).Trim()

Write-Host "Preparing Rocky Linux Marketplace image (resf:rockylinux-x86_64:9-base:latest)..." -ForegroundColor Cyan
$rockyUrn = "resf:rockylinux-x86_64:9-base:latest"
$termsJson = & az vm image terms accept --urn $rockyUrn --only-show-errors -o json 2>&1
if ($LASTEXITCODE -ne 0) { throw "Rocky Linux Marketplace terms could not be accepted: $($termsJson -join '`n')" }
$terms = ($termsJson -join "`n") | ConvertFrom-Json
if (-not $terms.accepted) { throw "Rocky Linux Marketplace terms were not accepted for $rockyUrn." }
Write-Host "Rocky Linux Marketplace terms accepted; Bicep VM resources include required plan metadata." -ForegroundColor Green

Ensure-ProjectResourceGroup -Name $hubRg -Location $HubLocation
Remove-IncompatibleMarketplaceVm -ResourceGroup $hubRg -VmNames @('vm-ts-jump-test','vm-ts-lead-test')
if ($jumpExists -and $leadExists) {
    Write-Host "`n[1/6] Existing compliant hub detected; reusing Jump and separate DevOps Lead VMs." -ForegroundColor Green
    Update-VmSshKey -ResourceGroup $hubRg -VmName 'vm-ts-jump-test' -Username $AdminUsername -PublicKey $sshPublicKey
    Update-VmSshKey -ResourceGroup $hubRg -VmName 'vm-ts-lead-test' -Username $AdminUsername -PublicKey $sshPublicKey
    $hubVnetName='vnet-ts-hub-test'
    $jumpPrivateIp=(& az network nic show -g $hubRg -n 'nic-ts-jump-test' --query 'ipConfigurations[0].privateIPAddress' -o tsv).Trim()
    $leadPrivateIp=(& az network nic show -g $hubRg -n 'nic-ts-lead-test' --query 'ipConfigurations[0].privateIPAddress' -o tsv).Trim()
    $jumpPublicIp=(& az network public-ip show -g $hubRg -n 'pip-ts-jump-test' --query ipAddress -o tsv).Trim()
    $hubVmSize=((& az vm show -g $hubRg -n 'vm-ts-jump-test' --query hardwareProfile.vmSize -o tsv).Trim())
} else {
    Write-Host "`n[1/6] Deploying hub in $HubLocation (separate Jump and DevOps Lead VMs)..." -ForegroundColor Cyan
    $hubDeployment=Deploy-HubWithSkuFallback -ResourceGroup $hubRg -TemplateFile (Join-Path $scriptRoot "hub.bicep") -AdminUsername $AdminUsername -SshPublicKey $sshPublicKey -Location $HubLocation -Candidates $hubPlan.Candidates -ExistingJumpSku $existingJumpSku -ExistingLeadSku $existingLeadSku
    $hubResult=$hubDeployment.Result
    $hubVmSize=$hubDeployment.Sku
    $jumpPrivateIp=$hubResult.properties.outputs.jumpPrivateIp.value
    $jumpPublicIp=$hubResult.properties.outputs.jumpPublicIp.value
    $leadPrivateIp=$hubResult.properties.outputs.leadPrivateIp.value
    $hubVnetName=$hubResult.properties.outputs.vnetName.value
    Write-Host "Selected hub SKU: $hubVmSize" -ForegroundColor Green
}

$devObjects=@()
$usedDeveloperRegions=@()
for($index=1;$index -le $developers.Count;$index++){
    $developer=$developers[$index-1]
    $slug=Convert-ToSlug "$($developer.ime)$($developer.prezime)"
    $displayName="$($developer.ime) $($developer.prezime)"
    $rg="rg-ts-$slug-test"
    $vnetPrefix="10.$index.0.0/16"
    $subnetPrefix="10.$index.1.0/24"
    $lbIp="10.$index.1.10"
    $blobName=New-StorageName -Slug $slug -Suffix "obj" -Hash $hash
    $fileName=New-StorageName -Slug $slug -Suffix "fil" -Hash $hash

    $expectedVmNames = @("vm-ts-$slug-app01", "vm-ts-$slug-app02")
    $existingVmJson = & az vm list -g $rg --only-show-errors -o json 2>$null
    $existingVms = if ($LASTEXITCODE -eq 0 -and $existingVmJson) {
        @(($existingVmJson -join "`n") | ConvertFrom-Json | Where-Object {
            $_.name -in $expectedVmNames -and $_.plan.name -eq '9-base' -and $_.plan.product -eq 'rockylinux-x86_64' -and $_.plan.publisher -eq 'resf'
        })
    } else { @() }
    $existingRegions = @($existingVms.location | Where-Object { $_ } | Select-Object -Unique)
    if ($existingRegions.Count -gt 1) { throw "Existing VMs for $displayName are split across regions; clean up the failed deployment first." }

    $regionOrder = @()
    if ($existingRegions.Count -eq 1 -and $existingRegions[0] -in $DeveloperRegionPool) {
        $regionOrder += $existingRegions[0]
    }
    for($offset=0;$offset -lt $DeveloperRegionPool.Count;$offset++){
        $regionOrder += $DeveloperRegionPool[(($index-1+$offset) % $DeveloperRegionPool.Count)]
    }
    $regionOrder = @($regionOrder | Select-Object -Unique)
    $regionOrder = @($regionOrder | Where-Object { $_ -and ($_ -notin $usedDeveloperRegions) -and ($_.ToLowerInvariant() -ne $HubLocation.ToLowerInvariant()) })
    $workDeployment=$null
    $devLocation=$null
    $devVnetName=$null
    $devSubnetName=$null
    $asgName=$null

    foreach($candidateRegion in $regionOrder){
        Write-Host "`nEvaluating region $candidateRegion for $displayName..." -ForegroundColor Magenta
        $existingHere = @($existingVms | Where-Object { $_.location -eq $candidateRegion })
        $reuseExistingPair = $false
        if ($existingHere.Count -eq 2 -and @($existingHere.hardwareProfile.vmSize | Select-Object -Unique).Count -eq 1) {
            $reuseExistingPair = $true
            $currentSku = [string]$existingHere[0].hardwareProfile.vmSize
            $skuPlan = [pscustomobject]@{
                Location=$candidateRegion
                Candidates=@([pscustomobject]@{Name=$currentSku;Family='existing';MemoryGB=0;Score=-2000})
                Reason='reusing existing pair'
            }
            Write-Host "Reusing existing VM pair with $currentSku; no new compute quota is required." -ForegroundColor Green
        } else {
            $missingVmCount = 2 - $existingHere.Count
            $preferredExistingSku = @($existingHere.hardwareProfile.vmSize | Where-Object { $_ } | Select-Object -Unique)
            $skuPlan = if ($missingVmCount -eq 2) {
                $developerRegionPlans[$candidateRegion.ToLowerInvariant()]
            } else {
                Get-EligibleSkuPlan -Location $candidateRegion -VmCount $missingVmCount -PreferSku $preferredExistingSku
            }
        }
        if (-not $skuPlan -or $skuPlan.Candidates.Count -eq 0) {
            Write-Warning "Skipping $candidateRegion before resource creation: $($skuPlan.Reason)."
            continue
        }

        Write-Host "Selected candidate shortlist: $(@($skuPlan.Candidates.Name) -join ', ')" -ForegroundColor Green
        Ensure-ProjectResourceGroup -Name $rg -Location $candidateRegion

        Write-Host "[2/6] Deploying isolated network for $displayName in $candidateRegion..." -ForegroundColor Cyan
        $netResult=Invoke-AzCli deployment group create --resource-group $rg --name "techsprint-$slug-network" --template-file (Join-Path $scriptRoot "developer-network.bicep") --parameters developerSlug=$slug addressPrefix=$vnetPrefix subnetPrefix=$subnetPrefix jumpPrivateIp=$jumpPrivateIp location=$candidateRegion --only-show-errors -o json|ConvertFrom-Json
        $candidateVnetName=$netResult.properties.outputs.vnetName.value
        $candidateSubnetName=$netResult.properties.outputs.subnetName.value
        $candidateAsgName=$netResult.properties.outputs.asgName.value

        Write-Host "[3/6] Creating GLOBAL hub/spoke peering for $displayName..." -ForegroundColor Cyan
        $hubVnetId=(Invoke-AzCli network vnet show -g $hubRg -n $hubVnetName --query id -o tsv).Trim()
        $devVnetId=(Invoke-AzCli network vnet show -g $rg -n $candidateVnetName --query id -o tsv).Trim()
        & az network vnet peering delete -g $hubRg --vnet-name $hubVnetName -n "peer-hub-to-$slug" 2>$null
        & az network vnet peering delete -g $rg --vnet-name $candidateVnetName -n "peer-$slug-to-hub" 2>$null
        Invoke-AzCli network vnet peering create -g $hubRg --vnet-name $hubVnetName -n "peer-hub-to-$slug" --remote-vnet $devVnetId --allow-vnet-access --allow-forwarded-traffic -o none|Out-Null
        Invoke-AzCli network vnet peering create -g $rg --vnet-name $candidateVnetName -n "peer-$slug-to-hub" --remote-vnet $hubVnetId --allow-vnet-access --allow-forwarded-traffic -o none|Out-Null

        Remove-IncompatibleMarketplaceVm -ResourceGroup $rg -VmNames @("vm-ts-$slug-app01","vm-ts-$slug-app02")
        if ($reuseExistingPair) {
            Write-Host "[4/6] Reusing existing workload without resubmitting immutable VM OS settings..." -ForegroundColor Cyan
            $vm1Name = "vm-ts-$slug-app01"
            $vm2Name = "vm-ts-$slug-app02"
            Update-VmSshKey -ResourceGroup $rg -VmName $vm1Name -Username $AdminUsername -PublicKey $sshPublicKey
            Update-VmSshKey -ResourceGroup $rg -VmName $vm2Name -Username $AdminUsername -PublicKey $sshPublicKey
            $vm1PrincipalId = (Invoke-AzCli vm show -g $rg -n $vm1Name --query identity.principalId --only-show-errors -o tsv).Trim()
            $vm2PrincipalId = (Invoke-AzCli vm show -g $rg -n $vm2Name --query identity.principalId --only-show-errors -o tsv).Trim()
            $blobId = (Invoke-AzCli storage account show -g $rg -n $blobName --query id --only-show-errors -o tsv).Trim()
            Invoke-AzCli storage account show -g $rg -n $fileName --query id --only-show-errors -o tsv | Out-Null
            Invoke-AzCli network lb show -g $rg -n "lb-ts-$slug-int" --query id --only-show-errors -o tsv | Out-Null
            $reusedResult = New-ReusedWorkloadResult -Vm1Name $vm1Name -Vm2Name $vm2Name -Vm1PrincipalId $vm1PrincipalId -Vm2PrincipalId $vm2PrincipalId -BlobStorageId $blobId -BlobStorageName $blobName -FileStorageName $fileName
            $candidateDeployment = [pscustomobject]@{Result=$reusedResult;Sku=$currentSku;Reused=$true}
        } else {
            Write-Host "[4/6] Deploying workload with the quota-eligible SKU shortlist..." -ForegroundColor Cyan
            $candidateDeployment=Deploy-WorkloadWithSkuFallback -ResourceGroup $rg -DeploymentName "techsprint-$slug-workload" -TemplateFile (Join-Path $scriptRoot "developer-workload.bicep") -DeveloperSlug $slug -DeveloperDisplayName $displayName -VnetName $candidateVnetName -SubnetName $candidateSubnetName -AsgName $candidateAsgName -LoadBalancerIp $lbIp -AdminUsername $AdminUsername -SshPublicKey $sshPublicKey -BlobStorageName $blobName -FileStorageName $fileName -Location $candidateRegion -Candidates $skuPlan.Candidates
        }
        if($candidateDeployment){
            $workDeployment=$candidateDeployment
            $devLocation=$candidateRegion
            $devVnetName=$candidateVnetName
            $devSubnetName=$candidateSubnetName
            $asgName=$candidateAsgName
            $usedDeveloperRegions += $candidateRegion
            break
        }

        Write-Warning "No compliant 2-vCPU / >=4-GiB capacity for $displayName in $candidateRegion. Moving this developer to another allowed region."
        & az network vnet peering delete -g $hubRg --vnet-name $hubVnetName -n "peer-hub-to-$slug" 2>$null
        Remove-TechSprintResourceGroup -Name $rg
    }

    if(-not $workDeployment){ throw "No allowed Azure region had validated capacity for the two required 2-vCPU / >=4-GiB Moodle VMs for $displayName." }

    $workResult=$workDeployment.Result
    Write-Host "Selected region/SKU for $displayName`: $devLocation / $($workDeployment.Sku)" -ForegroundColor Green
    $vm1=$workResult.properties.outputs.vm1Name.value
    $vm2=$workResult.properties.outputs.vm2Name.value
    $vm1Pid=$workResult.properties.outputs.vm1PrincipalId.value
    $vm2Pid=$workResult.properties.outputs.vm2PrincipalId.value
    $blobId=$workResult.properties.outputs.blobStorageId.value
    foreach($pid in @($vm1Pid,$vm2Pid)){
        Ensure-RoleAssignment -ObjectId $pid -PrincipalType ServicePrincipal -Role "Storage Blob Data Contributor" -Scope $blobId
    }
    $devObjects += [pscustomobject]@{User=$developer;Slug=$slug;DisplayName=$displayName;Location=$devLocation;ResourceGroup=$rg;VnetName=$devVnetName;LoadBalancerIp=$lbIp;Vm1=$vm1;Vm2=$vm2;BlobStorage=$blobName;FileStorage=$fileName;VmSize=$workDeployment.Sku}

}

Write-Host "`n[5/6] Creating least-privilege VM power role and CSV identities..." -ForegroundColor Cyan
$roleName="TechSprint VM Power Operator"
$existingRole=& az role definition list --name $roleName --query "[0].name" -o tsv 2>$null
if (-not $existingRole){
    $roleDefinition=@{Name=$roleName;IsCustom=$true;Description="Start, stop, deallocate and restart TechSprint virtual machines without changing VM configuration.";Actions=@("Microsoft.Resources/subscriptions/resourceGroups/read","Microsoft.Compute/virtualMachines/read","Microsoft.Compute/virtualMachines/instanceView/read","Microsoft.Compute/virtualMachines/start/action","Microsoft.Compute/virtualMachines/restart/action","Microsoft.Compute/virtualMachines/deallocate/action","Microsoft.Compute/virtualMachines/powerOff/action");NotActions=@();AssignableScopes=@("/subscriptions/$subscriptionId")}
    $rolePath=Join-Path $secretDir "vm-power-role.json";$roleDefinition|ConvertTo-Json -Depth 8|Set-Content $rolePath -Encoding utf8;Invoke-AzCli role definition create --role-definition $rolePath -o none|Out-Null
}

"TechSprint Entra identities - generated $(Get-Date -Format s)"|Set-Content $secretFile
$identityMode="EntraUsers"
foreach($dev in $devObjects){
    $upn=if($defaultDomain){"$($dev.User.ime).$($dev.User.prezime)@$defaultDomain".ToLowerInvariant()}else{""}
    $objectId=if($upn){(& az ad user show --id $upn --query id -o tsv 2>$null)}else{""}
    if (-not $objectId -and $upn){$password=New-RandomPassword;$createOutput=& az ad user create --display-name $dev.DisplayName --user-principal-name $upn --password $password --force-change-password-next-sign-in true -o json 2>&1;if ($LASTEXITCODE -eq 0){$objectId=($createOutput|ConvertFrom-Json).id;Add-Content $secretFile "$upn`t$password`t$objectId"}}
    $principalType='User'
    if (-not $objectId){$identityMode="ManagedIdentityFallback";$principalType='ServicePrincipal';$identityName="id-ts-$($dev.Slug)-developer";$idJson=Invoke-AzCli identity create -g $dev.ResourceGroup -n $identityName --location $dev.Location --tags project=techsprint environment=testing --only-show-errors -o json|ConvertFrom-Json;$objectId=$idJson.principalId;Add-Content $secretFile "$identityName`tMANAGED_IDENTITY`t$objectId"} elseif ($upn -and -not (Select-String -Path $secretFile -SimpleMatch $objectId -Quiet)) { Add-Content $secretFile "$upn`tEXISTING_USER`t$objectId"}
    $scope="/subscriptions/$subscriptionId/resourceGroups/$($dev.ResourceGroup)";Ensure-RoleAssignment -ObjectId $objectId -PrincipalType $principalType -Role $roleName -Scope $scope
}

$lead=$leads[0];$leadSlug=Convert-ToSlug "$($lead.ime)$($lead.prezime)";$leadDisplay="$($lead.ime) $($lead.prezime)";$leadUpn=if($defaultDomain){"$($lead.ime).$($lead.prezime)@$defaultDomain".ToLowerInvariant()}else{""};$leadObjectId=if($leadUpn){(& az ad user show --id $leadUpn --query id -o tsv 2>$null)}else{""};$leadPrincipalType='User'
if (-not $leadObjectId -and $leadUpn){$leadPassword=New-RandomPassword;$leadCreate=& az ad user create --display-name $leadDisplay --user-principal-name $leadUpn --password $leadPassword --force-change-password-next-sign-in true -o json 2>&1;if ($LASTEXITCODE -eq 0){$leadObjectId=($leadCreate|ConvertFrom-Json).id;Add-Content $secretFile "$leadUpn`t$leadPassword`t$leadObjectId"}}
if (-not $leadObjectId){$identityMode="ManagedIdentityFallback";$leadPrincipalType='ServicePrincipal';$leadIdentity=Invoke-AzCli identity create -g $hubRg -n "id-ts-$leadSlug-lead" --location $HubLocation --tags project=techsprint environment=testing --only-show-errors -o json|ConvertFrom-Json;$leadObjectId=$leadIdentity.principalId;Add-Content $secretFile "id-ts-$leadSlug-lead`tMANAGED_IDENTITY`t$leadObjectId"} elseif ($leadUpn -and -not (Select-String -Path $secretFile -SimpleMatch $leadObjectId -Quiet)) { Add-Content $secretFile "$leadUpn`tEXISTING_USER`t$leadObjectId"}
foreach($scopeRg in @($hubRg)+@($devObjects.ResourceGroup)){$scope="/subscriptions/$subscriptionId/resourceGroups/$scopeRg";Ensure-RoleAssignment -ObjectId $leadObjectId -PrincipalType $leadPrincipalType -Role $roleName -Scope $scope}

Write-Host "`n[6/6] Collecting deployment evidence..." -ForegroundColor Cyan
$summary=[ordered]@{Subscription=$account.name;SubscriptionId=$subscriptionId;TenantId=$tenantId;IdentityMode=$identityMode;HubLocation=$HubLocation;HubResourceGroup=$hubRg;JumpPublicIp=$jumpPublicIp;JumpPrivateIp=$jumpPrivateIp;LeadPrivateIp=$leadPrivateIp;HubVmSize=$hubVmSize;Developers=@($devObjects|ForEach-Object{[ordered]@{Name=$_.DisplayName;Location=$_.Location;ResourceGroup=$_.ResourceGroup;VNet=$_.VnetName;LoadBalancerIp=$_.LoadBalancerIp;VMs=@($_.Vm1,$_.Vm2);BlobStorage=$_.BlobStorage;FileStorage=$_.FileStorage;VmSize=$_.VmSize}})}
$summaryPath=Join-Path $scriptRoot "deployment-summary.json";$summary|ConvertTo-Json -Depth 8|Set-Content $summaryPath -Encoding utf8
Write-Host "`nDEPLOYMENT SUBMITTED SUCCESSFULLY" -ForegroundColor Green
Write-Host "Jump host public IP: $jumpPublicIp"
Write-Host "SSH: ssh -i $sshKeyPath $AdminUsername@$jumpPublicIp"
Write-Host "Summary: $summaryPath"
Write-Host "Identity details: $secretFile"
Write-Host "Moodle cloud-init can continue for several minutes after ARM deployment completes."
