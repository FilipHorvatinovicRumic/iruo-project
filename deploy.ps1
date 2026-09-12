param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,
    [string]$Location = "francecentral",
    [string]$AdminUsername = "azureadmin"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Invoke-AzCli {
    $output = & az @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ($output -join "`n")
    }
    return $output
}


function Test-SkuCapacityFailure {
    param([string]$Message)
    return ($Message -match 'SkuNotAvailable|Capacity Restrictions|AllocationFailed|OverconstrainedAllocationRequest|NotAvailableForSubscription')
}

function Deploy-HubWithSkuFallback {
    param(
        [string]$ResourceGroup,
        [string]$TemplateFile,
        [string]$AdminUsername,
        [string]$SshPublicKey,
        [string]$Location
    )

    $candidates = @(
        'Standard_B1ms',
        'Standard_B1s',
        'Standard_F1s_v2',
        'Standard_DS1_v2',
        'Standard_D1_v2',
        'Standard_A1_v2'
    )

    foreach ($sku in $candidates) {
        Write-Host "Trying hub VM SKU: $sku" -ForegroundColor DarkCyan
        $output = & az deployment group create --resource-group $ResourceGroup --name "techsprint-hub" --template-file $TemplateFile --parameters adminUsername=$AdminUsername sshPublicKey=$SshPublicKey location=$Location jumpVmSize=$sku leadVmSize=$sku --only-show-errors -o json 2>&1
        if ($LASTEXITCODE -eq 0) {
            return [pscustomobject]@{
                Result = (($output -join "`n") | ConvertFrom-Json)
                Sku = $sku
            }
        }

        $message = $output -join "`n"
        if (Test-SkuCapacityFailure -Message $message) {
            Write-Warning "SKU $sku is unavailable in $Location for this subscription/capacity. Trying the next 1-vCPU SKU."
            continue
        }
        throw $message
    }

    throw "No tested 1-vCPU hub VM SKU could be allocated in $Location. Candidates: $($candidates -join ', ')."
}

function Deploy-WorkloadWithSkuFallback {
    param(
        [string]$ResourceGroup,
        [string]$DeploymentName,
        [string]$TemplateFile,
        [string]$DeveloperSlug,
        [string]$DeveloperDisplayName,
        [string]$VnetName,
        [string]$SubnetName,
        [string]$AsgName,
        [string]$LoadBalancerIp,
        [string]$AdminUsername,
        [string]$SshPublicKey,
        [string]$BlobStorageName,
        [string]$FileStorageName,
        [string]$Location,
        [string]$PreferredSku = ''
    )

    $baseCandidates = @(
        'Standard_D1_v2',
        'Standard_DS1_v2',
        'Standard_F1s_v2',
        'Standard_B1ms',
        'Standard_B1s'
    )
    $candidates = if ($PreferredSku) { @($PreferredSku) + @($baseCandidates | Where-Object { $_ -ne $PreferredSku }) } else { $baseCandidates }

    foreach ($sku in $candidates) {
        Write-Host "Trying Moodle VM SKU for $DeveloperDisplayName`: $sku" -ForegroundColor DarkCyan
        $output = & az deployment group create --resource-group $ResourceGroup --name $DeploymentName --template-file $TemplateFile --parameters developerSlug=$DeveloperSlug developerDisplayName="$DeveloperDisplayName" vnetName=$VnetName subnetName=$SubnetName asgName=$AsgName loadBalancerIp=$LoadBalancerIp adminUsername=$AdminUsername sshPublicKey=$SshPublicKey blobStorageName=$BlobStorageName fileStorageName=$FileStorageName location=$Location appVmSize=$sku --only-show-errors -o json 2>&1
        if ($LASTEXITCODE -eq 0) {
            return [pscustomobject]@{
                Result = (($output -join "`n") | ConvertFrom-Json)
                Sku = $sku
            }
        }

        $message = $output -join "`n"
        if (Test-SkuCapacityFailure -Message $message) {
            Write-Warning "SKU $sku is unavailable for $DeveloperDisplayName in $Location. Trying the next 1-vCPU SKU."
            continue
        }
        throw $message
    }

    throw "No tested 1-vCPU Moodle VM SKU could be allocated in $Location for $DeveloperDisplayName."
}

function Ensure-ProjectResourceGroup {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Location
    )

    $existingLocation = & az group show --name $Name --query location -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $existingLocation) {
        $existingLocation = $existingLocation.Trim().ToLowerInvariant()
        if ($existingLocation -ne $Location.ToLowerInvariant()) {
            Write-Warning "Resource group '$Name' exists in '$existingLocation' but this deployment uses '$Location'. Deleting the stale TechSprint resource group and recreating it."
            Invoke-AzCli group delete --name $Name --yes --no-wait | Out-Null
            do {
                Start-Sleep -Seconds 5
                $stillExists = (& az group exists --name $Name -o tsv 2>$null).Trim()
            } while ($stillExists -eq 'true')
        } else {
            return
        }
    }

    Invoke-AzCli group create --name $Name --location $Location --tags project=techsprint environment=testing -o none | Out-Null
}

function Convert-ToSlug {
    param([string]$Text)
    $normalized = $Text.Normalize([Text.NormalizationForm]::FormD)
    $chars = foreach ($c in $normalized.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [Globalization.UnicodeCategory]::NonSpacingMark) { $c }
    }
    return ((-join $chars).Normalize([Text.NormalizationForm]::FormC).ToLowerInvariant() -replace '[^a-z0-9]', '')
}

function New-RandomPassword {
    $bytes = New-Object byte[] 18
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return "Ts!" + ([Convert]::ToBase64String($bytes) -replace '[+/=]', 'A').Substring(0, 20) + "9a"
}

function New-StorageName {
    param([string]$Slug, [string]$Suffix, [string]$Hash)
    $short = if ($Slug.Length -gt 7) { $Slug.Substring(0,7) } else { $Slug }
    return ("stts{0}{1}{2}" -f $short,$Hash,$Suffix).ToLowerInvariant()
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$csvFullPath = (Resolve-Path $CsvPath).Path
$users = Import-Csv -Path $csvFullPath -Delimiter ';'
$developers = @($users | Where-Object { $_.rola.Trim().ToLowerInvariant() -eq 'developer' })
$leads = @($users | Where-Object { $_.rola.Trim().ToLowerInvariant() -eq 'devops_lead' })

if ($developers.Count -lt 1) { throw "CSV mora sadržavati barem jednog developera." }
if ($leads.Count -ne 1) { throw "CSV mora sadržavati točno jednog devops_lead korisnika." }
if ($developers.Count -gt 2) { throw "Azure for Students demo je ograničen na 2 developera zbog regionalne kvote od 6 vCPU." }

$account = Invoke-AzCli account show -o json | ConvertFrom-Json
$subscriptionId = $account.id
$tenantId = $account.tenantId
$defaultDomain = ""
try {
    $defaultDomain = (Invoke-AzCli rest --method GET --url "https://graph.microsoft.com/v1.0/domains" --query "value[?isDefault].id | [0]" -o tsv).Trim()
} catch {
    Write-Warning "Default Entra domain could not be read. Infrastructure deployment will continue and IAM will use managed identity fallback."
}
$hashSource = [Text.Encoding]::UTF8.GetBytes($subscriptionId)
$sha = [Security.Cryptography.SHA256]::Create().ComputeHash($hashSource)
$hash = ([BitConverter]::ToString($sha).Replace('-', '').ToLowerInvariant()).Substring(0,4)
$tags = "project=techsprint environment=testing"
$hubRg = "rg-ts-hub-test"
$sshDir = Join-Path $HOME ".ssh"
$sshKeyPath = Join-Path $sshDir "techsprint_azure"
$secretDir = Join-Path $scriptRoot ".secrets"
$secretFile = Join-Path $secretDir "entra-users.txt"
New-Item -ItemType Directory -Force -Path $sshDir,$secretDir | Out-Null

if (-not (Test-Path $sshKeyPath)) {
    & ssh-keygen -t ed25519 -f $sshKeyPath -N "" -C "techsprint-project" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "SSH key generation failed." }
}
$sshPublicKey = (Get-Content "$sshKeyPath.pub" -Raw).Trim()

Write-Host "=== TechSprint Azure deployment ===" -ForegroundColor Cyan
Write-Host "Subscription: $($account.name)"
Write-Host "Location: $Location"
Write-Host "Developers: $($developers.Count)"
Write-Host "Bicep: $((Invoke-AzCli bicep version) -join ' ')"

Ensure-ProjectResourceGroup -Name $hubRg -Location $Location

Write-Host "`n[1/6] Deploying hub, jump host and DevOps Lead VM..." -ForegroundColor Cyan
$hubDeployment = Deploy-HubWithSkuFallback -ResourceGroup $hubRg -TemplateFile (Join-Path $scriptRoot "hub.bicep") -AdminUsername $AdminUsername -SshPublicKey $sshPublicKey -Location $Location
$hubResult = $hubDeployment.Result
$hubVmSize = $hubDeployment.Sku
Write-Host "Selected hub VM SKU: $hubVmSize" -ForegroundColor Green
$jumpPrivateIp = $hubResult.properties.outputs.jumpPrivateIp.value
$jumpPublicIp = $hubResult.properties.outputs.jumpPublicIp.value
$hubVnetName = $hubResult.properties.outputs.vnetName.value

$devObjects = @()
$selectedAppVmSize = ""
$index = 0
foreach ($developer in $developers) {
    $index++
    $slug = Convert-ToSlug "$($developer.ime)$($developer.prezime)"
    $displayName = "$($developer.ime) $($developer.prezime)"
    $rg = "rg-ts-$slug-test"
    $vnetPrefix = "10.$index.0.0/16"
    $subnetPrefix = "10.$index.1.0/24"
    $lbIp = "10.$index.1.10"
    $blobName = New-StorageName -Slug $slug -Suffix "obj" -Hash $hash
    $fileName = New-StorageName -Slug $slug -Suffix "fil" -Hash $hash

    Ensure-ProjectResourceGroup -Name $rg -Location $Location

    Write-Host "`n[2/6] Deploying isolated network for $displayName..." -ForegroundColor Cyan
    $netResult = Invoke-AzCli deployment group create --resource-group $rg --name "techsprint-$slug-network" --template-file (Join-Path $scriptRoot "developer-network.bicep") --parameters developerSlug=$slug addressPrefix=$vnetPrefix subnetPrefix=$subnetPrefix jumpPrivateIp=$jumpPrivateIp location=$Location --only-show-errors -o json | ConvertFrom-Json
    $devVnetName = $netResult.properties.outputs.vnetName.value
    $devSubnetName = $netResult.properties.outputs.subnetName.value
    $asgName = $netResult.properties.outputs.asgName.value

    Write-Host "[3/6] Creating hub/spoke peering for $displayName..." -ForegroundColor Cyan
    $hubVnetId = (Invoke-AzCli network vnet show -g $hubRg -n $hubVnetName --query id -o tsv).Trim()
    $devVnetId = (Invoke-AzCli network vnet show -g $rg -n $devVnetName --query id -o tsv).Trim()
    Invoke-AzCli network vnet peering create -g $hubRg --vnet-name $hubVnetName -n "peer-hub-to-$slug" --remote-vnet $devVnetId --allow-vnet-access --allow-forwarded-traffic -o none | Out-Null
    Invoke-AzCli network vnet peering create -g $rg --vnet-name $devVnetName -n "peer-$slug-to-hub" --remote-vnet $hubVnetId --allow-vnet-access --allow-forwarded-traffic -o none | Out-Null

    Write-Host "[4/6] Deploying Moodle workload, storage and load balancer for $displayName..." -ForegroundColor Cyan
    $preferredAppSku = if ($index -eq 1) { "" } else { $selectedAppVmSize }
    $workDeployment = Deploy-WorkloadWithSkuFallback -ResourceGroup $rg -DeploymentName "techsprint-$slug-workload" -TemplateFile (Join-Path $scriptRoot "developer-workload.bicep") -DeveloperSlug $slug -DeveloperDisplayName $displayName -VnetName $devVnetName -SubnetName $devSubnetName -AsgName $asgName -LoadBalancerIp $lbIp -AdminUsername $AdminUsername -SshPublicKey $sshPublicKey -BlobStorageName $blobName -FileStorageName $fileName -Location $Location -PreferredSku $preferredAppSku
    $workResult = $workDeployment.Result
    if ($index -eq 1) {
        $selectedAppVmSize = $workDeployment.Sku
        Write-Host "Selected Moodle VM SKU: $selectedAppVmSize" -ForegroundColor Green
    } elseif ($workDeployment.Sku -ne $selectedAppVmSize) {
        Write-Warning "Second developer required fallback SKU $($workDeployment.Sku) instead of $selectedAppVmSize due current Azure capacity/quota."
    }

    $vm1 = $workResult.properties.outputs.vm1Name.value
    $vm2 = $workResult.properties.outputs.vm2Name.value
    $vm1Pid = $workResult.properties.outputs.vm1PrincipalId.value
    $vm2Pid = $workResult.properties.outputs.vm2PrincipalId.value
    $blobId = $workResult.properties.outputs.blobStorageId.value

    foreach ($pid in @($vm1Pid,$vm2Pid)) {
        for ($attempt = 1; $attempt -le 8; $attempt++) {
            & az role assignment create --assignee-object-id $pid --assignee-principal-type ServicePrincipal --role "Storage Blob Data Contributor" --scope $blobId --only-show-errors -o none 2>$null
            if ($LASTEXITCODE -eq 0) { break }
            Start-Sleep -Seconds 10
        }
    }

    $devObjects += [pscustomobject]@{
        User = $developer
        Slug = $slug
        DisplayName = $displayName
        ResourceGroup = $rg
        VnetName = $devVnetName
        LoadBalancerIp = $lbIp
        Vm1 = $vm1
        Vm2 = $vm2
        BlobStorage = $blobName
        FileStorage = $fileName
        VmSize = $workDeployment.Sku
    }
}

Write-Host "`n[5/6] Creating least-privilege VM power role and CSV identities..." -ForegroundColor Cyan
$roleName = "TechSprint VM Power Operator"
$existingRole = & az role definition list --name $roleName --query "[0].name" -o tsv 2>$null
if (-not $existingRole) {
    $roleDefinition = @{
        Name = $roleName
        IsCustom = $true
        Description = "Start, stop, deallocate and restart TechSprint virtual machines without changing VM configuration."
        Actions = @(
            "Microsoft.Resources/subscriptions/resourceGroups/read",
            "Microsoft.Compute/virtualMachines/read",
            "Microsoft.Compute/virtualMachines/instanceView/read",
            "Microsoft.Compute/virtualMachines/start/action",
            "Microsoft.Compute/virtualMachines/restart/action",
            "Microsoft.Compute/virtualMachines/deallocate/action",
            "Microsoft.Compute/virtualMachines/powerOff/action"
        )
        NotActions = @()
        AssignableScopes = @("/subscriptions/$subscriptionId")
    }
    $rolePath = Join-Path $secretDir "vm-power-role.json"
    $roleDefinition | ConvertTo-Json -Depth 8 | Set-Content -Path $rolePath -Encoding utf8
    Invoke-AzCli role definition create --role-definition $rolePath -o none | Out-Null
}

"TechSprint Entra identities - generated $(Get-Date -Format s)" | Set-Content $secretFile
$identityMode = "EntraUsers"
foreach ($dev in $devObjects) {
    $upn = if ($defaultDomain) { "$($dev.User.ime).$($dev.User.prezime)@$defaultDomain".ToLowerInvariant() } else { "" }
    $objectId = if ($upn) { (& az ad user show --id $upn --query id -o tsv 2>$null) } else { "" }
    if (-not $objectId -and $upn) {
        $password = New-RandomPassword
        $createOutput = & az ad user create --display-name $dev.DisplayName --user-principal-name $upn --password $password --force-change-password-next-sign-in true -o json 2>&1
        if ($LASTEXITCODE -eq 0) {
            $objectId = ($createOutput | ConvertFrom-Json).id
            Add-Content $secretFile "$upn`t$password`t$objectId"
        }
    }
    if (-not $objectId) {
        $identityMode = "ManagedIdentityFallback"
        $identityName = "id-ts-$($dev.Slug)-developer"
        $idJson = Invoke-AzCli identity create -g $dev.ResourceGroup -n $identityName --location $Location --tags project=techsprint environment=testing -o json | ConvertFrom-Json
        $objectId = $idJson.principalId
        Add-Content $secretFile "$identityName`tMANAGED_IDENTITY`t$objectId"
    } elseif ($upn -and -not (Select-String -Path $secretFile -SimpleMatch $objectId -Quiet)) {
        Add-Content $secretFile "$upn`tEXISTING_USER`t$objectId"
    }
    $scope = "/subscriptions/$subscriptionId/resourceGroups/$($dev.ResourceGroup)"
    & az role assignment create --assignee-object-id $objectId --role $roleName --scope $scope --only-show-errors -o none 2>$null
}

$lead = $leads[0]
$leadSlug = Convert-ToSlug "$($lead.ime)$($lead.prezime)"
$leadDisplay = "$($lead.ime) $($lead.prezime)"
$leadUpn = if ($defaultDomain) { "$($lead.ime).$($lead.prezime)@$defaultDomain".ToLowerInvariant() } else { "" }
$leadObjectId = if ($leadUpn) { (& az ad user show --id $leadUpn --query id -o tsv 2>$null) } else { "" }
if (-not $leadObjectId -and $leadUpn) {
    $leadPassword = New-RandomPassword
    $leadCreate = & az ad user create --display-name $leadDisplay --user-principal-name $leadUpn --password $leadPassword --force-change-password-next-sign-in true -o json 2>&1
    if ($LASTEXITCODE -eq 0) {
        $leadObjectId = ($leadCreate | ConvertFrom-Json).id
        Add-Content $secretFile "$leadUpn`t$leadPassword`t$leadObjectId"
    }
}
if (-not $leadObjectId) {
    $identityMode = "ManagedIdentityFallback"
    $leadIdentity = Invoke-AzCli identity create -g $hubRg -n "id-ts-$leadSlug-lead" --location $Location --tags project=techsprint environment=testing -o json | ConvertFrom-Json
    $leadObjectId = $leadIdentity.principalId
    Add-Content $secretFile "id-ts-$leadSlug-lead`tMANAGED_IDENTITY`t$leadObjectId"
} elseif ($leadUpn -and -not (Select-String -Path $secretFile -SimpleMatch $leadObjectId -Quiet)) {
    Add-Content $secretFile "$leadUpn`tEXISTING_USER`t$leadObjectId"
}
foreach ($scopeRg in @($hubRg) + @($devObjects.ResourceGroup)) {
    $scope = "/subscriptions/$subscriptionId/resourceGroups/$scopeRg"
    & az role assignment create --assignee-object-id $leadObjectId --role $roleName --scope $scope --only-show-errors -o none 2>$null
}

Write-Host "`n[6/6] Collecting deployment evidence..." -ForegroundColor Cyan
$summary = [ordered]@{
    Subscription = $account.name
    SubscriptionId = $subscriptionId
    TenantId = $tenantId
    Location = $Location
    IdentityMode = $identityMode
    HubResourceGroup = $hubRg
    JumpPublicIp = $jumpPublicIp
    JumpPrivateIp = $jumpPrivateIp
    LeadPrivateIp = '10.0.0.5'
    HubVmSize = $hubVmSize
    Developers = @($devObjects | ForEach-Object {
        [ordered]@{
            Name = $_.DisplayName
            ResourceGroup = $_.ResourceGroup
            VNet = $_.VnetName
            LoadBalancerIp = $_.LoadBalancerIp
            VMs = @($_.Vm1,$_.Vm2)
            BlobStorage = $_.BlobStorage
            FileStorage = $_.FileStorage
            VmSize = $_.VmSize
        }
    })
}
$summaryPath = Join-Path $scriptRoot "deployment-summary.json"
$summary | ConvertTo-Json -Depth 8 | Set-Content $summaryPath -Encoding utf8

Write-Host "`nDEPLOYMENT SUBMITTED SUCCESSFULLY" -ForegroundColor Green
Write-Host "Jump host public IP: $jumpPublicIp"
Write-Host "SSH: ssh -i $sshKeyPath $AdminUsername@$jumpPublicIp"
Write-Host "Summary: $summaryPath"
Write-Host "Identity details: $secretFile"
Write-Host "Moodle cloud-init can continue for several minutes after ARM deployment completes."
