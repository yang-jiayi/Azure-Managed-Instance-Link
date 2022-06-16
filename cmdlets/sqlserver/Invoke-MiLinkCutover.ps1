function Invoke-MiLinkCutover {
    <#
    .SYNOPSIS
    Cmdlet that performs cutover from SQL Server (primary) to SQL managed Instance (secondary)
    
    .DESCRIPTION
    Cmdlet that performs cutover from SQL Server (primary) to SQL managed Instance (secondary)
    Cmdlet can be ran in interactive mode - or you can provide all necessary parameters in advance, fire, and forget :)
    Cmdlet supports ShouldProcess, can be dry-ran with -WhatIf parameter
    Cmdlet consists of 4 steps:
        1. switch replication mode to sync [if not ForcedFailover]
        2. compare LSNs [if not ForcedFailover]
        3. remove the link
        4. remove ags [optional]

    .PARAMETER ResourceGroupName
    Resource group name of Managed Instance 
    
    .PARAMETER ManagedInstanceName
    Managed Instance Name
    
    .PARAMETER SqlInstance
    Sql Server name
    
    .PARAMETER DatabaseName
    Database name
    
    .PARAMETER PrimaryAvailabilityGroup
    Primary availability group name
    
    .PARAMETER SecondaryAvailabilityGroup
    Secondary availability group name
    
    .PARAMETER LinkName
    Instance link name
    
    .PARAMETER ManagedInstanceCredential
    Managed Instance Credential
    
    .PARAMETER CleanupPreference
    One of { "KEEP_BOTH", "DELETE_DAG", "DELETE_AG_AND_DAG" }
    Defines actions on SQL Server upon deleting the link

    .PARAMETER ForcedCutover
    If set to true, we won't wait for replicas to be in sync (LSN to be equal) before cutting the link.
    If set to false, we will switch link mode to sync, and wait up to -WaitSecondsForSync for secondary replica to catch up before we exit the script
    
    .PARAMETER WaitSecondsForSync
    If set to true, we won't wait for replicas to be in sync (LSN to be equal) before cutting the link.
    If set to false, we will switch link mode to sync, and wait up to -WaitSecondsForSync for secondary replica to catch up before we exit the script
    Default value is 60 seconds.
    
    .EXAMPLE
    # Remove-Module Invoke-MiLinkCutover
    # Import-Module 'C:\{pathtoscript}\Invoke-MiLinkCutover.ps1'

    Invoke-MiLinkCutover -ResourceGroupName CustomerExperienceTeam_RG -ManagedInstanceName chimera-ps-cli-v2 `
    -SqlInstance chimera -DatabaseName basic -PrimaryAvailabilityGroup ag_basic -SecondaryAvailabilityGroup mi_basic -LinkName dag_basic  -Verbose 
    
    $cred = Get-Credential
    Invoke-MiLinkCutover -ResourceGroupName CustomerExperienceTeam_RG -ManagedInstanceName chimera-ps-cli-v2 `
    -SqlInstance chimera -DatabaseName basic -PrimaryAvailabilityGroup ag_basic -SecondaryAvailabilityGroup mi_basic `
    -LinkName dag_basic -ManagedInstanceCredential $cred -CleanupPreference "DELETE_AG_AND_DAG" -Verbose
 
    .NOTES
    General notes
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = "InteractiveParameterSet")]
    param (
        [Parameter(Mandatory = $true,
            ParameterSetName = 'InteractiveParameterSet',
            HelpMessage = 'Enter resource group name')]
        [Parameter(Mandatory = $true,
            ParameterSetName = 'NonInteractiveParameterSet',
            HelpMessage = 'Enter resource group name')]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true,
            ParameterSetName = 'InteractiveParameterSet',
            HelpMessage = 'Enter SQL managed instance name')]
        [Parameter(Mandatory = $true,
            ParameterSetName = 'NonInteractiveParameterSet',
            HelpMessage = 'Enter SQL managed instance name')]
        [string]$ManagedInstanceName,
        
        [Parameter(Mandatory = $true,
            ParameterSetName = 'InteractiveParameterSet',
            HelpMessage = 'Enter SQL Server name')]
        [Parameter(Mandatory = $true,
            ParameterSetName = 'NonInteractiveParameterSet',
            HelpMessage = 'Enter SQL Server name')]
        [string]$SqlInstance,

        [Parameter(Mandatory = $true,
            ParameterSetName = 'InteractiveParameterSet',
            HelpMessage = 'Enter target database name')]
        [Parameter(Mandatory = $true,
            ParameterSetName = 'NonInteractiveParameterSet',
            HelpMessage = 'Enter target database name')]
        [string]$DatabaseName,

        [Parameter(Mandatory = $true,
            ParameterSetName = 'InteractiveParameterSet',
            HelpMessage = 'Enter primary availability group name')]
        [Parameter(Mandatory = $true,
            ParameterSetName = 'NonInteractiveParameterSet',
            HelpMessage = 'Enter primary availability group name')]
        [string]$PrimaryAvailabilityGroup,

        [Parameter(Mandatory = $true,
            ParameterSetName = 'InteractiveParameterSet',
            HelpMessage = 'Enter primary availability group name')]
        [Parameter(Mandatory = $true,
            ParameterSetName = 'NonInteractiveParameterSet',
            HelpMessage = 'Enter secondary availability group name')]
        [string]$SecondaryAvailabilityGroup,

        [Parameter(Mandatory = $true,
            ParameterSetName = 'InteractiveParameterSet',
            HelpMessage = 'Enter instance link name')]
        [Parameter(Mandatory = $true,
            ParameterSetName = 'NonInteractiveParameterSet',
            HelpMessage = 'Enter instance link name')]
        [string]$LinkName,

        # auth params?
        [Parameter(Mandatory = $true,
            ParameterSetName = 'NonInteractiveParameterSet',
            HelpMessage = 'Enter managed instance credential')]
        [PSCredential]$ManagedInstanceCredential,

        [Parameter(Mandatory = $true,
            ParameterSetName = 'NonInteractiveParameterSet',
            HelpMessage = 'Enter cleanup preference')]
        [ValidateSet("KEEP_BOTH", "DELETE_DAG", "DELETE_AG_AND_DAG")]
        [ArgumentCompletions("KEEP_BOTH", "DELETE_DAG", "DELETE_AG_AND_DAG")]
        [String]$CleanupPreference,

        [Parameter(
            ParameterSetName = 'InteractiveParameterSet',
            HelpMessage = 'Forced cutover means we will not wait for replicas to be in sync')]
        [Parameter(Mandatory = $true,
            ParameterSetName = 'NonInteractiveParameterSet',
            HelpMessage = 'Forced cutover means we will not wait for replicas to be in sync')]
        [bool]$ForcedCutover,

        [Parameter(
            ParameterSetName = 'InteractiveParameterSet',
            HelpMessage = 'Number of seconds we will wait for secondary to catch up in case of non-forced cutover')]
        [Parameter(
            ParameterSetName = 'NonInteractiveParameterSet',
            HelpMessage = 'Number of seconds we will wait for secondary to catch up in case of non-forced cutover')]
        [int]$WaitSecondsForSync = 60
            
    )
    Begin {

        $interactiveMode = ($PsCmdlet.ParameterSetName -eq "InteractiveParameterSet")
        if ($interactiveMode) {
            $miCredential = Get-Credential -Message "Enter your SQL Managed instance credentials in order to login"
        }
        else {
            $miCredential = $ManagedInstanceCredential
        }
        Write-Verbose "Interactive mode enabled - $interactiveMode"
    }
    Process {
        $ErrorActionPreference = "Stop"

        # should we also do Connect-AzAccount and Set-AzContext?
        $managedInstance = Get-AzSqlInstance -ResourceGroupName $ResourceGroupName -Name $ManagedInstanceName

        if ($ForcedCutover) {
            # For ForcedCutover we won't attempt to synchronize replicas (although they may already be in sync)
            $flagAllowDataLoss = $true 
        }
        else {
            $querySyncModeSQL =
            @"
USE master;
ALTER AVAILABILITY GROUP [$LinkName]
MODIFY
AVAILABILITY GROUP ON
'$PrimaryAvailabilityGroup' WITH
(AVAILABILITY_MODE = SYNCHRONOUS_COMMIT),
'$SecondaryAvailabilityGroup' WITH
(AVAILABILITY_MODE = SYNCHRONOUS_COMMIT);
"@
            if ($PsCmdlet.ShouldProcess("SQL Server and SQL Mi", "Switch link replication mode to SYNC (planned failover)")) {
                Write-Verbose "Switching replication mode to SYNC [started]"
                Invoke-SqlCmd -Query $querySyncModeSQL -ServerInstance $SqlInstance
                Set-AzSqlInstanceLink -InstanceObject $managedInstance -LinkName $LinkName -ReplicationMode "SYNC"
                Write-Verbose "Switching replication mode to SYNC [completed]"
            }
 
            # Compare and ensure manually that LSNs are the same on SQL Server and Managed Instance
            Write-Verbose "Fetching LSN from replicas [started]"
            $queryLSN = 
            @"
SELECT drs.last_hardened_lsn
FROM sys.dm_hadr_database_replica_states drs
WHERE drs.database_id = DB_ID(N'$DatabaseName')
AND drs.is_primary_replica = 1
"@
            $sqlLSN = (Invoke-SqlCmd -Query $queryLSN -ServerInstance $SqlInstance ).last_hardened_lsn
            $miLSN = (Invoke-SqlCmd -Query $queryLSN -ServerInstance $managedInstance.FullyQualifiedDomainName -Credential $miCredential).last_hardened_lsn
            Write-Verbose "Fetching LSN from replicas [completed]"
            Write-Host "SQL Server lsn is {$sqlLSN}, SQL managed instance lsn is {$miLSN}"
                
            # Give some time to secondary replica to catch up. We won't continue if we're not in sync
            Write-Verbose "Waiting for replicas to be in sync [started]"
            $currWait = 0
            while (($sqlLSN -ne $miLSN) -and ($currWait -lt $WaitSecondsForSync)) {
                Start-Sleep -Seconds 7                    
                $sqlLSN = (Invoke-SqlCmd -Query $queryLSN -ServerInstance $SqlInstance ).last_hardened_lsn
                $miLSN = (Invoke-SqlCmd -Query $queryLSN -ServerInstance $managedInstance.FullyQualifiedDomainName -Credential $miCredential).last_hardened_lsn
                Write-Verbose "Waiting for secondary to catch up. SQL Server lsn is {$sqlLSN}, SQL managed instance lsn is {$miLSN}"
            }
            if ($sqlLSN -ne $miLSN) {
                throw "LSNs are not equal on primary and secondary. Consider re-running script later, or with greater WaitSecondsForSync value, or with -ForcedCutover arg"
            }
            Write-Verbose "Waiting for replicas to be in sync [completed]"
            Write-Host "LSNs are equal on primary and secondary. SQL Server lsn is {$sqlLSN}, SQL managed instance lsn is {$miLSN}"    
            $flagAllowDataLoss = $true # we could also leave it false for InteractiveMode, but it shouldn't matter as LSNs are in sync at this point
        }
        
        # We should [optionally] clean up DAG and AG once the link's removed
        if ($PsCmdlet.ShouldProcess("SQL Server and SQL Mi", "Removing the link and availability groups")) {
            Write-Verbose "Removing instance link [started]"
            Remove-AzSqlInstanceLink -ResourceGroupName $ResourceGroupName -InstanceName $ManagedInstanceName -LinkName $LinkName -AllowDataLoss:$flagAllowDataLoss
            Write-Verbose "Removing instance link [completed]"

            if ($interactiveMode) {
                if ($PSCmdlet.ShouldContinue("Do you want to remove availability group $primaryAG?", "Link Cutover")) {
                    $CleanupPreference = "DELETE_AG_AND_DAG"
                }
                else {
                    if ($PSCmdlet.ShouldContinue("Do you want to remove distributed availability group $LinkName?", "Link Cutover")) {
                        $CleanupPreference = "DELETE_DAG"
                    }
                }
            }

            if ($CleanupPreference -eq "DELETE_AG_AND_DAG") { 
                Write-Verbose "Dropping availability groups [started]"
                Invoke-SqlCmd -Query "DROP AVAILABILITY GROUP [$LinkName]" -ServerInstance $SqlInstance
                Invoke-SqlCmd -Query "DROP AVAILABILITY GROUP [$PrimaryAvailabilityGroup]" -ServerInstance $SqlInstance
                Write-Verbose "Dropping availability groups [completed]"
            }
            elseif ($CleanupPreference = "DELETE_DAG") {
                Write-Verbose "Dropping distributed availability group [started]"
                Invoke-SqlCmd -Query "DROP AVAILABILITY GROUP [$LinkName]" -ServerInstance $SqlInstance
                Write-Verbose "Dropping distributed availability group [completed]"
            }
        }
    }
}
