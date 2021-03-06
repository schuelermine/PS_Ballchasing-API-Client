# ANCHOR Main functions

function Test-APIStatus {
    param (
        [Switch]$DoAPICheck
    )

    $URL = "https://ballchasing.com"

    Test-Connection $URL
    $Success = $?

    if ($Success -and $DoAPICheck.IsPresent) {
        Invoke-WebRequest $URL -SkipHttpErrorCheck
        $Success = $?
    }

    $Success
}

function Test-APIKey {
    param (
        [Parameter(Mandatory)]
        [String]$APIKey
    )

    $Request = @{
        Headers = @{ Authorization = $APIKey }
        Uri     = "https://ballchasing.com/api/"
    }

    try {
        $Response = Invoke-WebRequest -SkipHttpErrorCheck @Request
        $StatusCode = $Response.StatusCode
        $Content = $Response.Content
    }
    catch {
        Write-Host "Possibly invalid API key format"
        return $false
    }
    
    if ($StatusCode -ne 200) {
        try {
            $Exception = ($Content | ConvertFrom-Json).error

            Write-Error "Ballchasing API returned this error:"
            Write-Error $Exception
        }
        catch {
            Write-Error "No error returned, but the status code was not 200"
            Write-Error "Status code: $StatusCode"
        }
        
        $true
        exit 1
    }
    else {
        $false
        exit
    }
}

function Get-ReplayIDs {
    param (
        [Parameter(Mandatory)]
        [String]$APIKey,

        [ValidateNotNull()]
        [Hashtable]$Parameters = @()
    )

    Test-APIKey -APIKey $APIKey
    if (-not $?) {
        exit 1
    }

    $URIParameterString = ConvertTo-URIParameterString -Parameters $Parameters
    $ReplayWebRequest = @{
        Headers = @{ Authorization = $APIKey }
        Uri     = "https://ballchasing.com/api/replays$URIParameterString"
    }

    $Response = Invoke-WebRequest @ReplayWebRequest | ConvertTo-Json
    $Replays = $Response.list | ForEach-Object id
    
    $NextURL = $Response.next
    if ($null -ne $NextURL) {
        $Replays += Get-NextReplayIDs -APIKey $APIKey -URL $NextURL
    }

    return $Replays
}

function Get-MyReplayIDs {
    param (
        [Parameter(Mandatory)]
        [String]$APIKey
    )

    $APIKeyIsValid = Test-APIKey -APIKey $APIKey
    if (-not $APIKeyIsValid) {
        return $null
    }

    $ReplayWebRequest = @{
        Headers = @{ Authorization = $APIKey }
        Uri     = "https://ballchasing.com/api/replays?uploader=me&count=200"
    }

    $Response = Invoke-WebRequest @ReplayWebRequest | ConvertFrom-Json
    $Replays = $Response.list | ForEach-Object { return $_.id }
    $NextURL = $Response.next
    if ($null -ne $NextURL) {
        $Replays += Get-NextReplayIDs -APIKey $APIKey -URL $NextURL
    }

    return $Replays
}

function Get-NextReplayIDs {
    param (
        [Parameter(Mandatory)]
        [String]$APIKey,

        [Parameter(Mandatory)]
        [String]$URL
    )

    $NextWebRequest = @{
        Headers = @{ Authorization = $APIKey }
        Uri     = $URL
    }

    $Response = Invoke-WebRequest @NextWebRequest | ConvertFrom-Json
    $Replays = $Response.list | ForEach-Object { return $_.id }
    $NextURL = $Response.next
    
    if ($null -ne $NextURL) {
        $Replays += Get-NextReplayIDs -APIKey $APIKey -URL $NextURL
    }

    return $Replays
}

function Get-SingleReplayContentByID {
    param (
        [String]$ReplayID,
        [String]$OutputFolder,
        [Int32]$Delay,
        [Switch]$SkipDelay,
        [Switch]$Overwrite,
        [Switch]$KeepFile
    )

    if (-not $PSBoundParameters.ContainsKey("Delay")) {
        $Delay = 500
    }
    
    $DidRequest = $false
    $Done = $false
    $OutputPath = "$OutputFolder\$ReplayID.replay"
    $DataWebRequest = @{
        SkipHttpErrorCheck = $true
        PassThru           = $true
        OutFile            = $OutputPath
        Method             = "Post"
        Uri                = "https://ballchasing.com/dl/replay/$ReplayID"
    }

    
    if ((Test-Path $OutputPath)) {
        if ($KeepFile) {
            $Remove = $false
        }
        elseif ($Overwrite) {
            $Remove = $true
        }
        elseif (-not $Overwrite) {
            $UserChoice =
                Read-Host -Prompt "The file $OutputPath already exists. Overwrite it? [Y/n]"
            
            if ($UserChoice -match "n") {
                $Remove = $false
            }
            else {
                $Remove = $true
            }
        }

        if ($Remove) {
            Remove-Item $OutputPath
            Write-Host "Exising file removed"
        }
        else {
            $Done = $true
            Write-Host "Skipping existing file"
        }
    }

    while (-not $Done) {
        $StatusCode = (Invoke-WebRequest @DataWebRequest).StatusCode

        $DidRequest = $true

        if ($StatusCode -ne 200) {
            Write-Host "Failed getting replay, retrying in 60 seconds"
            if ((Test-Path $OutputPath)) {
                Remove-Item $OutputPath
            }
            Start-Sleep -Milliseconds 60000
        }
        else {
            $Done = $true
            Write-Host "$ReplayID `t - Success"
        }
    }

    if (-not $SkipDelay) {
        Start-Sleep -Milliseconds $Delay
    }

    return $DidRequest
}

function Get-ReplayContentsByIDs {
    param (
        [String]$OutputFolder,
        [Int32]$SafetyDelay,
        [Switch]$Overwrite,
        [Switch]$KeepFiles
    )

    begin {
        $Counter = [UInt32]0
        $Timer = [System.Diagnostics.Stopwatch]::StartNew()
        $Timer.Stop()
        $GetDataParameters = @{
            ReplayID     = $_
            KeepFile     = $KeepFiles
            OutputFolder = $OutputFolder
            SkipDelay    = $true
        }
    }

    process {
        $Timer.Start()
        $DidRequest =
            Get-SingleReplayContentByID @GetDataParameters
        $Timer.Stop()

        if ($DidRequest) {
            $Counter += 1
        }

        if ($Counter -ge 15 -and $Timer.ElapsedMilliseconds -le 60000) {
            $Wait = $SafetyDelay + 60000 - $Timer.ElapsedMilliseconds
            Start-Sleep -Milliseconds $Wait
            Write-Host "Waiting for $Wait seconds to obey rate limits"
            $Counter = [UInt32]0
        }
        elseif ($Timer.ElapsedMilliseconds -le 1000) {
            $Wait = $SafetyDelay + 1000 - $Timer.ElapsedMilliseconds
            Start-Sleep -Milliseconds $Wait
        }

        $Timer.Reset()
    }
}

# ANCHOR Helper functions
function ConvertTo-URIParameterString {
    param (
        [Hashtable]$Parameters
    )

    $Keys = $Parameters.Keys
    $Result = $Keys | ForEach-Object { "$_=" + $Parameters.Item($_) }
    $Result = "?" + ($Result -join "&")

    return $Result
}

Export-ModuleMember -Function Test-APIKey,
    Get-ReplayIDs,
    Get-MyReplayIDs,
    Get-SingleReplayContentByID,
    Get-ReplayContentsByIDs