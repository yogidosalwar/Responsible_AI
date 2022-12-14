# ---------------------------------------------------------
# Copyright (c) Microsoft Corporation. All rights reserved.
# ---------------------------------------------------------

# Obtains a workspace for running tests
# If a workspace younger than window_seconds exists, it will be reused
# If not, a fresh workspace will be created
# Most of the tracking is actually done through the parent resource groups
# If cullWorkspaces is set, then workspaces older than 2*window_seconds are deleted

# This also produces two JSON files used by subsequent scripts:
# config.json -> A regular workspace config JSON file
# component_config.json -> Specifies the version of everything to upload (as epoch_seconds)

$baseName = "amlisdkv2"
$location = $env:WORKSPACE_LOCATION
$createdTag = "createdAt"
$ownerTeamTagKey = "owningTeam"
$ownerTeamTagValue = "AML_Intelligence"
$purposeTagKey = "workspacePurpose"
$purposeTagValue = "Automated_Tests_for_DPv2"
$workspaceYAML = "workspace.yaml"
$window_seconds = $env:WORKSPACE_WINDOW_SECONDS
$cullWorkspaces = $env:OLD_WORKSPACES_HANDLING -eq "Cull"

function Get-RecentResourceGroups(
    [int]$min_epoch,
    [string]$target_location
) {
    # Returns resource groups created after the time specified by min_epoch
    # and in target_location
    # Uses the createdTag for this purpose
    Write-Host "Searching for recent resource groups"
    Write-Host "Minimum Epoch: $min_epoch"
    # Would be nice to do this server-side
    $all_groups = az group list --output json | ConvertFrom-Json

    $filtered_groups = $all_groups.Where(
        { 
            $_.name.contains($baseName) -and
            $_.tags.$createdTag -gt $min_epoch -and
            $_.location -eq $target_location
        }
    )

    $sorted_groups = $filtered_groups | Sort-Object -Descending -Property {$_.name}

    return $sorted_groups
}


function Get-OldResourceGroups(
    [int]$max_epoch
) {
    # Returns resource groups created before the time specified by max_epoch
    # Uses the createdTag for this purpose
    Write-Host "Searching for older resource groups"
    Write-Host "Maximum Epoch: $max_epoch"
    # Would be nice to do this server-side
    $all_groups = az group list | ConvertFrom-Json

    $filtered_groups = $all_groups.Where({ $_.name.contains($baseName) -and $_.tags.$createdTag -lt $max_epoch })

    return $filtered_groups
}

function Get-WorkspaceFromResourceGroup(
    [string]$resource_group_name
) {
    Write-Host "Checking resource group $resource_group_name"
    $workspaces = az ml workspace list --resource-group $resource_group_name --output json | ConvertFrom-Json

    $filtered_workspaces = $workspaces.Where({ $_.name.contains($baseName) })

    if ($filtered_workspaces.count -gt 0) {
        $workspace = $workspaces[0]
    }
    else {
        throw "Resource Group did not contain workspace with name starting with $baseName"
    }

    return $workspace
}

function Get-EpochSecs {
    # Get time to nearest second
    $epoch_time = Get-Date (Get-Date).ToUniversalTime() -UFormat %s
    $epoch_secs = [Math]::Truncate($epoch_time)
    return $epoch_secs
}

function Create-EpochWorkspace(
    [int]$epoch_secs,
    [string]$target_location
) {
    $rg_name = "$basename-rg-$epoch_secs"
    $ws_name = "$basename$epoch_secs"

    Write-Host "Creating workspace $ws_name in resource group $rg_name in region $target_location"

    $ws_data = @{}
    $ws_data['name'] = $ws_name
    $ws_data['tags'] = @{}
    $ws_data['tags'][$createdTag] = "$epoch_secs"
    $ws_data['tags'][$ownerTeamTagKey] = $ownerTeamTagValue
    $ws_data['tags'][$purposeTagKey] = $purposeTagValue

    ConvertTo-Yaml $ws_data | Out-File -FilePath $workspaceYAML -Encoding ascii

    $rg = az group create --location $target_location --name $rg_name --tags "$createdTag=$epoch_secs" --debug
    Write-Host "Resource group created"
    Write-Host $rg
    $ws = az ml workspace create --resource-group $rg_name --file $workspaceYAML | ConvertFrom-Json
    return $ws
}

function Create-ConfigJson(
    $workspace
) {
    if (Get-Member -inputobject $workspace -name "storageAccount" -Membertype Properties) {
        Write-Host "Getting storage account via storageAccount."
        $parts = $workspace.storageAccount.split('/')
    }
    else {
        Write-Host "Getting storage account via storage_account."
        $parts = $workspace.storage_account.split('/')
    }

    $sub_id = $parts[2]
    $rg_name = $parts[4]
    Write-Host "Extracted subscription: $sub_id"
    Write-Host "Extract resource group: $rg_name"

    $json_config = @{}
    $json_config["subscription_id"] = $sub_id
    $json_config["resource_group"] = $rg_name
    $json_config["workspace_name"] = $workspace.name

    ConvertTo-Json $json_config | Out-File -FilePath 'config.json' -Encoding ascii
}

function Create-ComponentConfigJson(
    [int]$epoch_secs
) {
    $json_config = @{}
    $json_config['version'] = $epoch_secs

    ConvertTo-Json $json_config | Out-File -FilePath 'component_config.json' -Encoding ascii
}

# Install-Module powershell-yaml -Scope CurrentUser

$epoch_secs = Get-EpochSecs

if ( $cullWorkspaces ) {
    Write-Host "Checking for old resource groups"
    Write-Host 
    $old_rg_list = Get-OldResourceGroups($epoch_secs - 2 * $window_seconds)
    if ( $old_rg_list.count -gt 0) {
        Write-Host "Found $($old_rg_list.count) resource groups to clean up"
        foreach ( $rg in $old_rg_list) {
            Write-Host "Cleaning up $($rg.name)"
            az group delete --name $rg.name --yes
        }
    }
    else {
        Write-Host "No old resource groups found"
    }
}
else {
    Write-Host "Skipping old resource group check"
}

Write-Host
Write-Host "Creating workspace if one not found"
Write-Host

$rg_list = Get-RecentResourceGroups -min_epoch ($epoch_secs - $window_seconds) -target_location $location
if ($rg_list.count -eq 0) {
    Write-Host "No recent workspace, creating new one"
    $_ = Create-EpochWorkspace -epoch_secs $epoch_secs -target_location $location
}

$rg_list = Get-RecentResourceGroups -min_epoch ($epoch_secs - $window_seconds) -target_location $location
Write-Host "Found $($rg_list.count) suitable resource groups"
$target_rg = $rg_list[0].name
$workspace = Get-WorkspaceFromResourceGroup($target_rg)


Write-Host
Write-Host "Workspace information"
Write-Host
Write-Host ($workspace | ConvertTo-Json)
Write-Host

Write-Host
Write-Host "Creating config.json"
Write-Host

Create-ConfigJson($workspace)

Write-Host
Write-Host "Creating component_config.json"
Write-Host

Create-ComponentConfigJson($epoch_secs)

