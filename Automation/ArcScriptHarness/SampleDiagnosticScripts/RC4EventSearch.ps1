#Requires -Version 5.1
<##
.SYNOPSIS
    Returns the last 50 System event log entries with IDs greater than 200 and less than 210.
    Designed to run via ArcScriptHarness.ps1.

.NOTES
    Version: 1.0.0
#>
$script:Version = '1.0.0'

$eventXPath = '*[System[(EventID > 200) and (EventID < 210)]]'

try {
    Get-WinEvent -LogName System -FilterXPath $eventXPath -MaxEvents 50 -ErrorAction Stop |
        ForEach-Object {
        $userName = if ($_.UserId) {
            try {
                $_.UserId.Translate([System.Security.Principal.NTAccount]).Value
            } catch {
                $_.UserId.Value
            }
        } else {
            $null
        }

        $description = if ($_.Message) {
            $messageLines = ($_.Message -replace '\r\n?', "`n") -split "`n"
            ($messageLines | Where-Object { $_.Trim().Length -gt 0 }) -join [Environment]::NewLine
        } else {
            $null
        }

            Write-Output ([PSCustomObject]@{
                TimeGenerated       = $_.TimeCreated.ToLocalTime()
                Computer             = $_.MachineName
                'Event ID'           = $_.Id
                Source               = $_.ProviderName
                'Event Level Name'   = $_.LevelDisplayName
                UserName             = $userName
                Description          = $description
            })
        }
} catch {
    if ($_.Exception.Message -match 'No events were found that match the specified selection criteria') {
        Write-Output 'No events were found that match the search criteria.'
    } else {
        throw
    }
}
