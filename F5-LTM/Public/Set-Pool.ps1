﻿Function Set-Pool {
    <#
        .SYNOPSIS
            Create or update Pool(s)
        .DESCRIPTION
            Can create new or update existing Pool(s).
        .PARAMETER InputObject
            The content of the Pool.
        .PARAMETER Application
            The iApp of the Pool.
        .PARAMETER Partition
            The partition on the F5 to put the Pool on.
        .PARAMETER PassThru
            Output the modified Pool to the pipeline.
        .EXAMPLE
            Set-Pool -Name 'test.northwindtraders.com' -Description 'Northwind Traders example' -DefaultPool 'test.northwindtraders.com_blue' -Source 0.0.0.0/0 -DestinationIP 192.168.15.98 -DestinationPort 30785 -ipProtocol tcp

            Creates or updates a Pool.  Note that parameters that are Mandatory for New-Pool must be specified for Pools that do not yet exist.
            
        .EXAMPLE
            Set-Pool -Name 'test.northwindtraders.com' -DestinationPort 82
            
            Sets the destination port of an existing Pool.
            
        .EXAMPLE
            $vs = Get-Pool -Name 'test.northwindtraders.com'
            $vs.pool = if ($vs.pool -eq 'test.northwindtraders.com_blue') { 'test.northwindtraders.com_green' } else { 'test.northwindtraders.com_blue' }
            $vs | Set-Pool -PassThru

            Toggles the pool of an existing Pool via the pipeline and returns the resulting Pool with -PassThru.
            
    #>
    [cmdletbinding(ConfirmImpact='Medium',SupportsShouldProcess,DefaultParameterSetName="Default")]
    param (
        $F5Session=$Script:F5Session,

        [Parameter(Mandatory,ParameterSetName='InputObject',ValueFromPipeline)]
        [Alias('Pool')]
        [PSObject[]]$InputObject,

        #region Immutable fullPath component params

        [Alias('PoolName')]
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        $Name,

        [Alias('iApp')]
        [Parameter(ValueFromPipelineByPropertyName)]
        $Application='',

        [Parameter(ValueFromPipelineByPropertyName)]
        $Partition='Common',

        #endregion

        #region New-Pool equivalents
        
        [string]$Description,

        [ValidateSet('dynamic-ratio-member','dynamic-ratio-node','fastest-app-response','fastest-node','least-connections-members','least-connections-node','least-sessions','observed-member','observed-node','predictive-member','predictive-node','ratio-least-connections-member','ratio-least-connections-node','ratio-member','ratio-node','ratio-session','round-robin','weighted-least-connections-member','weighted-least-connections-node')]
        [string]$LoadBalancingMode,

        [string[]]$MemberDefinitionList,

        #endregion

        [switch]$PassThru
    )
    
    begin {
        Test-F5Session -F5Session ($F5Session)

        Write-Verbose "NB: Pool names are case-specific."

        $knownproperties = @{
            name='name'
            partition='partition'
            kind='kind'
            description='description'
            loadBalancingMode='loadBalancingMode'
            membersReference='membersReference'
            monitor='monitor'
        }
    }
    
    process {
        if ($InputObject -and (
                ($Name -and $Name -cne $InputObject.name) -or
                ($Partition -and $Partition -cne $InputObject.partition) -or
                ($Application -and $Application -cne $InputObject.application)
            )
        ) {
            throw 'Set-Pool does not support moving or renaming at this time.  Use New-Pool and Remove-Pool.'
        }

        $NewProperties = @{} # A hash table to facilitate splatting of New-Pool params
        $ChgProperties = @{} # A hash table of PSBoundParameters to override InputObject properties
        
        # Build out both hashtables based on $PSBoundParameters
        foreach ($key in $PSBoundParameters.Keys) {
            switch ($key) {
                'InputObject' {} # Ignore
                'PassThru' {} # Ignore
                { @('F5Session','MemberDefinitionList') -contains $key } {
                    $NewProperties[$key] = $PSBoundParameters[$key]
                }
                default {
                    if ($knownproperties.ContainsKey($key)) {
                        $NewProperties[$key] = $ChgProperties[$knownproperties[$key]] = $PSBoundParameters[$key]
                    }
                }
            }
        }
        
        $ExistingPool = Get-Pool -F5Session $F5Session -Name $Name -Application $Application -Partition $Partition -ErrorAction SilentlyContinue

        if ($null -eq $ExistingPool) {
            Write-Verbose -Message 'Creating new Pool...'
            $null = New-Pool @NewProperties
        }
        # This performs the magic necessary for ChgProperties to override $InputObject properties
        $NewObject = Join-Object -Left $InputObject -Right ([pscustomobject]$ChgProperties) -Join FULL -WarningAction SilentlyContinue
        if ($NewObject -ne $null -and $pscmdlet.ShouldProcess($F5Session.Name, "Setting Pool $Name")) {
            Write-Verbose -Message 'Setting Pool details...'
                
            $URI = $F5Session.BaseURL + 'pool/{0}' -f (Get-ItemPath -Name $Name -Application $Application -Partition $Partition) 
            $JSONBody = $NewObject | ConvertTo-Json -Compress

            #region case-sensitive parameter names

            # If someone inputs their own custom PSObject with properties with unexpected case, this will correct the case of known properties.
            # It could arguably be removed.  If not removed, it should be refactored into a shared (Private) function for use by all Set-* functions in the module.
            $knownRegex = '(?<=")({0})(?=":)' -f ($knownproperties.Keys -join '|')
            # Use of regex.Replace with a callback is more efficient than multiple, separate replacements
            $JsonBody = [regex]::Replace($JSONBody,$knownRegex,{param($match) $knownproperties[$match.Value] }, [Text.RegularExpressions.RegexOptions]::IgnoreCase)

            #endregion

            $result = Invoke-F5RestMethod -Method PATCH -URI "$URI" -F5Session $F5Session -Body $JSONBody -ContentType 'application/json'

            # MemberDefinitionList should trump existing members IFF there is an ExistingPool, otherwise New-Pool will take care of initializing the members.
            if ($MemberDefinitionList -and $ExistingPool) {
                # Remove all existing pool members
                Get-PoolMember -F5Session $F5Session -PoolName $Name -Partition $Partition | Remove-PoolMember -F5Session $F5Session -Confirm:$false
                # Add requested pool members
                ForEach ($MemberDefinition in $MemberDefinitionList){
                    $Node,$PortNumber = $MemberDefinition -split ','
                    # IP Addresses always start with a number, server names can not
                    if ($Node -match '^\d') {
                        $null = Add-PoolMember -F5Session $F5Session -PoolName $Name -Partition $Partition -Address $Node -PortNumber $PortNumber -Status Enabled
                    } else {
                        $null = Add-PoolMember -F5Session $F5Session -PoolName $Name -Partition $Partition -ComputerName $Node -PortNumber $PortNumber -Status Enabled
                    }
                }
            }
        }
        if ($PassThru) { Get-Pool -F5Session $F5Session -Name $Name -Application $Application -Partition $Partition }
    }
}