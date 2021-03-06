﻿[cmdletbinding()]
param 
(
    [Parameter(Mandatory=$false, HelpMessage="The path to the Deployment Template File ")]
    [string] $TemplatePath = "https://backupbocconiimagelab.blob.core.windows.net/upload/BOCCONI_MultiVMCustomImageTemplate.json",

    # Instance Count
    [Parameter(Mandatory=$true, HelpMessage="Number of instances to create")]
    [int] $VMCount,

    # Lab Name
    [Parameter(Mandatory=$true, HelpMessage="Name of Lab")]
    [string] $LabName,

    # Base Image
    [Parameter(Mandatory=$true, HelpMessage="Name of base image in lab")]
    [string] $BaseImage,

    # Image Size
    [Parameter(Mandatory=$false, HelpMessage="Size of VM image")]
    [string] $ImageSize = "Standard_A2_v2",    

    # New VM name
    [Parameter(Mandatory=$false, HelpMessage="Prefix for new VMs")]
    [string] $newVMName = "studentlabvm",

    # Shutdown time for each VM
    [Parameter(Mandatory=$true, HelpMessage="Scheduled shutdown for class. In form of 'HH:mm'")]
    [string] $ShutDownTime
)

#$global:VerbosePreference = $VerbosePreference

$VerbosePreference = "continue"

#NOTE: important to upload the "ClassHelper.psm1" module in the Azure Automation account
#$rootFolder = Split-Path ($Script:MyInvocation.MyCommand.Path)
#Import-Module (Join-Path $rootFolder "ClassHelper.psm1")

# Stops at the first error instead of continuing and potentially messing up things
#$global:erroractionpreference = 1
LogOutput -msg "Begin Process" 
$startTime = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
$deploymentName = "Deployment_$LabName_$startTime"

# Load the credentials
#LoadProfile $profilePath

$connectionName = "AzureRunAsConnection"
$SubId = Get-AutomationVariable -Name 'SubscriptionId'
try
{
   # Get the connection "AzureRunAsConnection "
   $servicePrincipalConnection=Get-AutomationConnection -Name $connectionName         

   "Signing in to Azure..."
   Add-AzureRmAccount `
     -ServicePrincipal `
     -TenantId $servicePrincipalConnection.TenantId `
     -ApplicationId $servicePrincipalConnection.ApplicationId `
     -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint
   "Setting context to a specific subscription"     
   Set-AzureRmContext -SubscriptionId $SubId              
}
catch {
    if (!$servicePrincipalConnection)
    {
       $ErrorMessage = "Connection $connectionName not found."
       throw $ErrorMessage
     } else{
        Write-Error -Message $_.Exception
        throw $_.Exception
     }
}

# Set the Subscription ID
$SubscriptionID = (Get-AzureRmContext).Subscription.SubscriptionId

$ResourceGroupName = (Find-AzureRmResource -ResourceType "Microsoft.DevTestLab/labs" -ResourceNameContains $LabName).ResourceGroupName

# Check to see if any VMs already exist in the lab. 
# Assume if ANY VMs exist then 
#   a) each VM is a VM for the class
#   b) has not been cleaned up 
#   thus the script should exit
# 
LogOutput "Checking for existing VMs in $LabName"
$existingVMs = (Find-AzureRmResource -ResourceType "Microsoft.DevTestLab/labs/virtualMachines" -ResourceNameContains $newVMName -ResourceGroupNameContains $ResourceGroupName).Count

if ($existingVMs -ne 0) {
    # Fatal error encountered. Log Error/Notify and Exit Script
    LogError "Lab $LabName contains $existingVMs existing VMs. Please clean up lab before creating new VMs"
    Exit 1
}

# Result object to return
$result = @{}
$result.statusCode = "Not Started"
$result.statusMessage = "Start class process pending execution"
$result.Failed = @()
$result.Succeeded = @()

# Set the expiration Date
$UniversalDate = (Get-Date).ToUniversalTime()
$ExpirationDate = $UniversalDate.AddDays(1).ToString("yyyy-MM-dd")
LogOutput "Expiration Date: $ExpirationDate"

# Set the shutdown time
$endTime = Get-Date $ShutDownTime
$endTime = $endTime.toString("HHmm")
LogOutput "Class End Time: $($endTime)"

$parameters = @{}
$parameters.Add("count",$VMCount)
$parameters.Add("labName",$LabName)
$parameters.Add("newVMName", $newVMName)
$parameters.Add("size", $ImageSize)
$parameters.Add("expirationDate", $ExpirationDate)
$parameters.Add("imageName", $BaseImage)
$parameters.Add("shutDownTime", $endTime)

# deploy resources via template
try {
    LogOutput "Starting Deployment $deploymentName for lab $LabName"
    $result.statusCode = "Started"
    $result.statusMessage = "Beginning template deployment"
    $vmDeployResult = New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroup $ResourceGroupName -TemplateFile $TemplatePath -TemplateParameterObject $parameters 
} 
catch {
    $result.errorCode = $_.Exception.GetType().FullName
    $result.errorMessage = $_.Exception.Message
    LogError "Exception: $($result.errorCode) Message: $($result.errorMessage)"
}
finally {
    #Even if we got an error from the deployment call, get the deployment operation statuses for more invformation
    $ops = Get-AzureRmResourceGroupDeploymentOperation -DeploymentName $deploymentName -SubscriptionId $SubscriptionID -ResourceGroupName $ResourceGroupName
    
    $deploymentEval = ($ops | Where-Object {$_.properties.provisioningOperation -eq "EvaluateDeploymentOutput"}).Properties
    
    $result.statusCode = $deploymentEval.statusCode
    $result.statusMessage = $deploymentEval.statusMessage    

    # process each deployment operation. separate into succeeded and failed buckets    
    ($ops | Where-Object {$_.properties.provisioningOperation -ne "EvaluateDeploymentOutput"}).Properties | ForEach-Object {        
        $task = @{}
        $task.name = $_.targetResource.ResourceName
        $task.type = $_.targetResource.ResourceType
        $task.statusCode = $_.targetResource.statusCode
        $task.statusMessage= $_.targetResource.statusMessage
        if ($_.provisioningState -eq "Succeeded") {                
            $result.Succeeded += $task
        } else {
            $result.Failed += $task
        }
    }    

    $vmsCreated = ($result.Succeeded | Where-Object {$_.type -eq "Microsoft.DevTestLabs/labs/virtualmachines"}).Count
    $subResourcesCreated = ($result.Succeeded | Where-Object {$_.type -ne "Microsoft.DevTestLabs/labs/virtualmachines"}).Count
    
    LogOutput "Status for VM creation in lab $($LabName): $($result.statusCode)"
    LogOutput "Target VMs: $VMCount"
    LogOutput "VMs Succesfully created: $vmsCreated"
    LogOutput "VM Sub-Resources Succesfully created: $subResourcesCreated"
    LogOutput "VMs Failed: $($result.Failed.Count)"
    
}

LogOutput "Process complete"
return $result