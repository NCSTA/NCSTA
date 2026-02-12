# StagingDb.psm1 - Local SQLite staging database for tracking DNS changes
# Uses System.Data.SQLite via ADO.NET or falls back to Microsoft.Data.Sqlite

$script:DbPath = $null
$script:Connection = $null

function Initialize-StagingDb {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $script:DbPath = $Path
    $dbDir = Split-Path $Path -Parent
    if (-not (Test-Path $dbDir)) {
        New-Item -Path $dbDir -ItemType Directory -Force | Out-Null
    }

    $connString = "Data Source=$Path;Version=3;"
    $script:Connection = New-Object System.Data.SQLite.SQLiteConnection($connString)
    $script:Connection.Open()

    $createTable = @"
CREATE TABLE IF NOT EXISTS staged_changes (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    record_type     TEXT NOT NULL,
    record_name     TEXT NOT NULL,
    zone_name       TEXT NOT NULL,
    record_value    TEXT NOT NULL,
    ttl             INTEGER DEFAULT 300,
    action          TEXT NOT NULL,
    deploy_mode     TEXT NOT NULL DEFAULT 'manual',
    scheduled_time  TEXT,
    created_by      TEXT NOT NULL,
    created_at      TEXT NOT NULL DEFAULT (datetime('now','localtime')),
    deployed_at     TEXT,
    status          TEXT NOT NULL DEFAULT 'pending',
    bam_entity_id   INTEGER,
    deployment_id   INTEGER,
    error_message   TEXT,
    comment         TEXT
);
"@

    $cmd = $script:Connection.CreateCommand()
    $cmd.CommandText = $createTable
    $cmd.ExecuteNonQuery() | Out-Null
    $cmd.Dispose()
}

function Close-StagingDb {
    if ($script:Connection -and $script:Connection.State -eq 'Open') {
        $script:Connection.Close()
        $script:Connection.Dispose()
        $script:Connection = $null
    }
}

function Add-StagedChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RecordType,
        [Parameter(Mandatory)][string]$RecordName,
        [Parameter(Mandatory)][string]$ZoneName,
        [Parameter(Mandatory)][string]$RecordValue,
        [int]$TTL = 300,
        [Parameter(Mandatory)][ValidateSet('create','modify','delete')][string]$Action,
        [ValidateSet('manual','immediate','scheduled')][string]$DeployMode = 'manual',
        [datetime]$ScheduledTime,
        [Parameter(Mandatory)][string]$CreatedBy,
        [int]$BamEntityId,
        [string]$Comment
    )

    $sql = @"
INSERT INTO staged_changes
    (record_type, record_name, zone_name, record_value, ttl, action, deploy_mode, scheduled_time, created_by, bam_entity_id, comment)
VALUES
    (@type, @name, @zone, @value, @ttl, @action, @mode, @scheduled, @user, @entityId, @comment);
SELECT last_insert_rowid();
"@

    $cmd = $script:Connection.CreateCommand()
    $cmd.CommandText = $sql
    $cmd.Parameters.AddWithValue("@type", $RecordType) | Out-Null
    $cmd.Parameters.AddWithValue("@name", $RecordName) | Out-Null
    $cmd.Parameters.AddWithValue("@zone", $ZoneName) | Out-Null
    $cmd.Parameters.AddWithValue("@value", $RecordValue) | Out-Null
    $cmd.Parameters.AddWithValue("@ttl", $TTL) | Out-Null
    $cmd.Parameters.AddWithValue("@action", $Action) | Out-Null
    $cmd.Parameters.AddWithValue("@mode", $DeployMode) | Out-Null

    if ($ScheduledTime) {
        $cmd.Parameters.AddWithValue("@scheduled", $ScheduledTime.ToString("yyyy-MM-dd HH:mm:ss")) | Out-Null
    } else {
        $cmd.Parameters.AddWithValue("@scheduled", [DBNull]::Value) | Out-Null
    }

    $cmd.Parameters.AddWithValue("@user", $CreatedBy) | Out-Null

    if ($BamEntityId -gt 0) {
        $cmd.Parameters.AddWithValue("@entityId", $BamEntityId) | Out-Null
    } else {
        $cmd.Parameters.AddWithValue("@entityId", [DBNull]::Value) | Out-Null
    }

    if ($Comment) {
        $cmd.Parameters.AddWithValue("@comment", $Comment) | Out-Null
    } else {
        $cmd.Parameters.AddWithValue("@comment", [DBNull]::Value) | Out-Null
    }

    $newId = $cmd.ExecuteScalar()
    $cmd.Dispose()
    return [int]$newId
}

function Update-StagedChangeStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][ValidateSet('pending','deploying','deployed','failed','cancelled')][string]$Status,
        [int]$DeploymentId,
        [int]$BamEntityId,
        [string]$ErrorMessage
    )

    $setParts = @("status = @status")
    if ($Status -eq 'deployed') {
        $setParts += "deployed_at = datetime('now','localtime')"
    }
    if ($DeploymentId -gt 0) {
        $setParts += "deployment_id = @deployId"
    }
    if ($BamEntityId -gt 0) {
        $setParts += "bam_entity_id = @entityId"
    }
    if ($ErrorMessage) {
        $setParts += "error_message = @error"
    }

    $sql = "UPDATE staged_changes SET $($setParts -join ', ') WHERE id = @id"

    $cmd = $script:Connection.CreateCommand()
    $cmd.CommandText = $sql
    $cmd.Parameters.AddWithValue("@status", $Status) | Out-Null
    $cmd.Parameters.AddWithValue("@id", $Id) | Out-Null

    if ($DeploymentId -gt 0) {
        $cmd.Parameters.AddWithValue("@deployId", $DeploymentId) | Out-Null
    }
    if ($BamEntityId -gt 0) {
        $cmd.Parameters.AddWithValue("@entityId", $BamEntityId) | Out-Null
    }
    if ($ErrorMessage) {
        $cmd.Parameters.AddWithValue("@error", $ErrorMessage) | Out-Null
    }

    $cmd.ExecuteNonQuery() | Out-Null
    $cmd.Dispose()
}

function Get-StagedChanges {
    [CmdletBinding()]
    param(
        [ValidateSet('all','pending','deployed','failed','scheduled','cancelled')][string]$Filter = 'all',
        [int]$Limit = 200
    )

    $where = switch ($Filter) {
        'pending'   { "WHERE status = 'pending'" }
        'deployed'  { "WHERE status = 'deployed'" }
        'failed'    { "WHERE status = 'failed'" }
        'scheduled' { "WHERE deploy_mode = 'scheduled' AND status = 'pending'" }
        'cancelled' { "WHERE status = 'cancelled'" }
        default     { "" }
    }

    $sql = "SELECT * FROM staged_changes $where ORDER BY created_at DESC LIMIT @limit"

    $cmd = $script:Connection.CreateCommand()
    $cmd.CommandText = $sql
    $cmd.Parameters.AddWithValue("@limit", $Limit) | Out-Null

    $adapter = New-Object System.Data.SQLite.SQLiteDataAdapter($cmd)
    $table = New-Object System.Data.DataTable
    $adapter.Fill($table) | Out-Null

    $cmd.Dispose()
    $adapter.Dispose()

    return $table
}

function Get-ScheduledPendingJobs {
    [CmdletBinding()]
    param()

    $sql = @"
SELECT * FROM staged_changes
WHERE deploy_mode = 'scheduled'
  AND status = 'pending'
  AND scheduled_time <= datetime('now','localtime')
ORDER BY scheduled_time ASC
"@

    $cmd = $script:Connection.CreateCommand()
    $cmd.CommandText = $sql

    $adapter = New-Object System.Data.SQLite.SQLiteDataAdapter($cmd)
    $table = New-Object System.Data.DataTable
    $adapter.Fill($table) | Out-Null

    $cmd.Dispose()
    $adapter.Dispose()

    return $table
}

function Remove-StagedChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Id
    )

    $cmd = $script:Connection.CreateCommand()
    $cmd.CommandText = "DELETE FROM staged_changes WHERE id = @id AND status IN ('pending','failed','cancelled')"
    $cmd.Parameters.AddWithValue("@id", $Id) | Out-Null
    $rows = $cmd.ExecuteNonQuery()
    $cmd.Dispose()
    return $rows
}

Export-ModuleMember -Function Initialize-StagingDb, Close-StagingDb, Add-StagedChange,
    Update-StagedChangeStatus, Get-StagedChanges, Get-ScheduledPendingJobs, Remove-StagedChange
