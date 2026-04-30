<#
.SYNOPSIS
    Identify Power BI datasets and dataflows at risk when regular users are
    removed from gateway / cloud connection access.

.DESCRIPTION
    For each dataset, calls Get Datasources As Admin to check whether it uses a
    gateway connection, then flags items where the configuredBy owner is NOT one
    of the designated service accounts.

    Authentication uses Azure CLI (az account get-access-token).
    The signed-in identity must have Power BI admin permissions
    (Fabric Administrator or Power BI Administrator role).
#>

# ── Configuration ────────────────────────────────────────────────────────────

$PBI_SCOPE = "https://analysis.windows.net/powerbi/api/.default"
$BASE_URL  = "https://api.powerbi.com/v1.0/myorg/admin"

$ALL_OWNERS_FILE = "pbi_owners.csv"
$AT_RISK_FILE    = "pbi_at_risk.csv"

# ── Load .env ────────────────────────────────────────────────────────────────

function Import-DotEnv {
    $envFile = Join-Path $PSScriptRoot ".env"
    if (Test-Path $envFile) {
        Get-Content $envFile | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not $line.StartsWith("#")) {
                $parts = $line -split "=", 2
                if ($parts.Count -eq 2) {
                    [Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1].Trim(), "Process")
                }
            }
        }
    }
}

# ── Authentication ───────────────────────────────────────────────────────────

function Get-PBIAccessToken {
    <# Acquire an access token using the Azure CLI logged-in user. #>
    $tokenJson = az account get-access-token --resource "https://analysis.windows.net/powerbi/api" --query "accessToken" -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to acquire token via Azure CLI. Run 'az login' first."
        exit 1
    }
    return $tokenJson
}

# ── API helpers ──────────────────────────────────────────────────────────────

function Get-AllPages {
    <# Follow @odata.nextLink pagination and return all entities. #>
    param(
        [string]$Url,
        [hashtable]$Headers
    )
    $items = @()
    while ($Url) {
        $resp = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get -TimeoutSec 60
        if ($resp.value) {
            $items += $resp.value
        }
        $Url = $resp.'@odata.nextLink'
    }
    return , $items
}

function Get-PBIDatasets {
    param([hashtable]$Headers)
    return Get-AllPages -Url "$BASE_URL/datasets" -Headers $Headers
}

function Get-PBIDataflows {
    param([hashtable]$Headers)
    return Get-AllPages -Url "$BASE_URL/dataflows" -Headers $Headers
}

function Get-DatasourcesForDataset {
    param(
        [string]$DatasetId,
        [hashtable]$Headers
    )
    $url = "$BASE_URL/datasets/$DatasetId/datasources"
    try {
        $resp = Invoke-WebRequest -Uri $url -Headers $Headers -Method Get -TimeoutSec 60 -ErrorAction Stop
        return (ConvertFrom-Json $resp.Content).value
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -eq 404) {
            return @()
        }
        if ($statusCode -eq 429) {
            $retryAfter = 30
            $retryHeader = $_.Exception.Response.Headers["Retry-After"]
            if ($retryHeader) { $retryAfter = [int]$retryHeader }
            Write-Host "  ⏳ Rate-limited, waiting ${retryAfter}s …"
            Start-Sleep -Seconds $retryAfter
            return Get-DatasourcesForDataset -DatasetId $DatasetId -Headers $Headers
        }
        throw
    }
}

function Test-UsesGateway {
    <# Return $true and the gateway ID if any datasource is bound to a gateway. #>
    param([array]$Datasources)
    foreach ($ds in $Datasources) {
        $gwId = $ds.gatewayId
        if ($gwId -and $gwId -ne "00000000-0000-0000-0000-000000000000") {
            return @{ UsesGateway = $true; GatewayId = $gwId }
        }
    }
    return @{ UsesGateway = $false; GatewayId = "" }
}

# ── Main ─────────────────────────────────────────────────────────────────────

Import-DotEnv

$raw = [Environment]::GetEnvironmentVariable("PBI_SERVICE_ACCOUNTS", "Process")
if (-not $raw -or -not $raw.Trim()) {
    Write-Error ("Set PBI_SERVICE_ACCOUNTS in your .env file (comma-separated UPNs).`n" +
                 "Example:  PBI_SERVICE_ACCOUNTS=svc1@contoso.com,svc2@contoso.com")
    exit 1
}

$safeAccounts = @{}
$raw.Split(",") | Where-Object { $_.Trim() } | ForEach-Object {
    $safeAccounts[$_.Trim().ToLower()] = $true
}

Write-Host "Service accounts (safe): $(($safeAccounts.Keys | Sort-Object) -join ', ')`n"

$token   = Get-PBIAccessToken
$headers = @{ "Authorization" = "Bearer $token" }

# ── Fetch datasets ───────────────────────────────────────────────────────
Write-Host "Fetching datasets …"
$datasets = Get-PBIDatasets -Headers $headers
Write-Host "  → $($datasets.Count) dataset(s) found"

Write-Host "Checking datasources per dataset (this may take a while) …"
$allRows    = [System.Collections.Generic.List[PSCustomObject]]::new()
$atRiskRows = [System.Collections.Generic.List[PSCustomObject]]::new()

for ($i = 0; $i -lt $datasets.Count; $i++) {
    $ds         = $datasets[$i]
    $datasetId  = if ($ds.id)           { $ds.id }           else { "" }
    $name       = if ($ds.name)         { $ds.name }         else { "" }
    $owner      = if ($ds.configuredBy) { $ds.configuredBy } else { "" }
    $workspace  = if ($ds.workspaceId)  { $ds.workspaceId }  else { "" }

    $datasources = Get-DatasourcesForDataset -DatasetId $datasetId -Headers $headers
    $gwResult    = Test-UsesGateway -Datasources $datasources

    $dsTypes = @()
    if ($datasources -and $datasources.Count -gt 0) {
        $dsTypes = $datasources | ForEach-Object {
            if ($_.datasourceType) { $_.datasourceType } else { "Unknown" }
        } | Sort-Object -Unique
    }

    $isAtRisk = $gwResult.UsesGateway -and -not $safeAccounts.ContainsKey($owner.Trim().ToLower())

    $row = [PSCustomObject]@{
        Type            = "Dataset"
        WorkspaceId     = $workspace
        Id              = $datasetId
        Name            = $name
        ConfiguredBy    = $owner
        CreatedDate     = if ($ds.createdDate)     { $ds.createdDate }     else { "" }
        LastRefreshTime = if ($ds.lastRefreshTime) { $ds.lastRefreshTime } else { "" }
        UsesGateway     = $gwResult.UsesGateway.ToString()
        GatewayId       = $gwResult.GatewayId
        DatasourceTypes = ($dsTypes -join "; ")
        AtRisk          = $isAtRisk.ToString()
    }

    $allRows.Add($row)
    if ($isAtRisk) { $atRiskRows.Add($row) }

    $num = $i + 1
    if ($num % 10 -eq 0 -or $num -eq $datasets.Count) {
        Write-Host "  … $num/$($datasets.Count) datasets checked" -NoNewline
        Write-Host "`r" -NoNewline
    }
}
Write-Host ""

# ── Fetch dataflows ──────────────────────────────────────────────────────
Write-Host "Fetching dataflows …"
$dataflows = Get-PBIDataflows -Headers $headers
Write-Host "  → $($dataflows.Count) dataflow(s) found"

foreach ($df in $dataflows) {
    $owner = if ($df.configuredBy) { $df.configuredBy } else { "" }
    $isAtRisk = -not $safeAccounts.ContainsKey($owner.Trim().ToLower())

    $row = [PSCustomObject]@{
        Type            = "Dataflow"
        WorkspaceId     = if ($df.workspaceId)       { $df.workspaceId }       else { "" }
        Id              = if ($df.objectId)           { $df.objectId }           else { "" }
        Name            = if ($df.name)               { $df.name }               else { "" }
        ConfiguredBy    = $owner
        CreatedDate     = if ($df.modelCreatedDate)   { $df.modelCreatedDate }   else { "" }
        LastRefreshTime = if ($df.modifiedDateTime)   { $df.modifiedDateTime }   else { "" }
        UsesGateway     = "N/A"
        GatewayId       = ""
        DatasourceTypes = ""
        AtRisk          = $isAtRisk.ToString()
    }

    $allRows.Add($row)
    if ($isAtRisk) { $atRiskRows.Add($row) }
}

# ── Write CSVs ───────────────────────────────────────────────────────────
$allRows    | Export-Csv -Path $ALL_OWNERS_FILE -NoTypeInformation -Encoding UTF8
$atRiskRows | Export-Csv -Path $AT_RISK_FILE    -NoTypeInformation -Encoding UTF8

# ── Summary ──────────────────────────────────────────────────────────────
Write-Host "`nAll items  → $ALL_OWNERS_FILE  ($($allRows.Count) rows)"
Write-Host "At-risk    → $AT_RISK_FILE  ($($atRiskRows.Count) rows)"

if ($atRiskRows.Count -gt 0) {
    $impactedUsers = $atRiskRows |
        Where-Object { $_.ConfiguredBy } |
        Select-Object -ExpandProperty ConfiguredBy -Unique |
        Sort-Object

    Write-Host "`n⚠  $($atRiskRows.Count) item(s) at risk, owned by $($impactedUsers.Count) user(s):"
    foreach ($user in $impactedUsers) {
        $userItems = $atRiskRows | Where-Object { $_.ConfiguredBy -eq $user }
        Write-Host "   • $user  ($($userItems.Count) item(s))"
        foreach ($item in $userItems) {
            Write-Host "       – [$($item.Type)] $($item.Name)"
        }
    }
}
else {
    Write-Host "`n✅  No at-risk items found. All datasets/dataflows are owned by service accounts."
}
