# Requires ImportExcel module for xlsx export:
# Install-Module -Name ImportExcel -Scope CurrentUser

$CsvPath = "C:\Temp\GroupOwners.csv"
$OutPath = "C:\Temp\GroupOwners.xlsx"

Write-Host "Loading CSV: $CsvPath ..." -ForegroundColor Cyan
$data = @(Import-Csv -Path $CsvPath)
$total = $data.Count
Write-Host "Loaded $total rows." -ForegroundColor Cyan

$i = 0
$cache = @{}
$cacheHits = 0
$adQueries = 0
$skipped = 0

foreach ($row in $data) {
    $i++
    Write-Progress -Activity "Processing groups" `
        -Status "$i / $total ($adQueries AD queries, $cacheHits cache hits, $skipped skipped)" `
        -PercentComplete ([math]::Min(100, ($i / $total) * 100))

    # Skip if already filled or ID is empty
    if ($row.'ID Owner' -or -not $row.ID) {
        $skipped++
        continue
    }

    try {
        # Split "domain\group-name" into domain and group
        $parts  = $row.ID -split '\\', 2
        $domain = $parts[0]
        $grp    = $parts[1]
        $cacheKey = "$domain\$grp"

        # Check cache first
        if ($cache.ContainsKey($cacheKey)) {
            $row.'ID Owner' = $cache[$cacheKey]
            $cacheHits++
            continue
        }

        # Not cached - query AD for the single group member
        $adQueries++
        $members = @(Get-ADGroupMember -Identity $grp -Server $domain -ErrorAction Stop)

        if ($members.Count -eq 1) {
            $cache[$cacheKey] = $members[0].Name
        }
        elseif ($members.Count -eq 0) {
            $cache[$cacheKey] = "No members found"
        }
        else {
            $cache[$cacheKey] = ($members | ForEach-Object { $_.Name }) -join '; '
        }

        $row.'ID Owner' = $cache[$cacheKey]
    }
    catch {
        $errorMsg = "ERROR: $($_.Exception.Message)"
        $cache[$cacheKey] = $errorMsg
        $row.'ID Owner' = $errorMsg
    }
}

Write-Progress -Activity "Processing groups" -Completed

# Export results to xlsx
$data | Export-Excel -Path $OutPath -WorksheetName "GroupOwners" -AutoSize -ClearSheet

Write-Host ""
Write-Host "===== Complete =====" -ForegroundColor Green
Write-Host "Total rows:    $total"
Write-Host "AD queries:    $adQueries"
Write-Host "Cache hits:    $cacheHits"
Write-Host "Skipped:       $skipped"
Write-Host "Unique groups: $($cache.Count)"
Write-Host "Output file:   $OutPath"
