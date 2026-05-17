# =============================================================================
# createTables.ps1
# Legt die beiden Log Analytics Custom Tables an.
# Authentifizierung via Azure Arc Managed Identity (kein Client Secret nötig).
#
# Voraussetzungen:
#   - Script läuft auf einem Azure Arc-joined Server
#   - Managed Identity hat "Contributor" oder "Log Analytics Contributor"
#	 auf dem Log Analytics Workspace
# =============================================================================

# ── Konfiguration ─────────────────────────────────────────────────────────────
$SubscriptionId	= "<SUBSCRIPTION-ID>"
$ResourceGroup	 = "<RESOURCE-GROUP>"
$WorkspaceName	 = "<LOG-ANALYTICS-WORKSPACE-NAME>"
$ApiVersion		= "2022-10-01"

$scriptDir		 = Split-Path -Parent $MyInvocation.MyCommand.Definition

# ── Token via Arc Managed Identity holen ─────────────────────────────────────
# Arc Connected Machine Agent stellt IMDS auf Port 40342 bereit (kein VM-IMDS)
Write-Host "Hole Managed Identity Token vom Arc IMDS..." -ForegroundColor Cyan

try {
	$imdsResponse = Invoke-WebRequest `
		-Uri "http://localhost:40342/metadata/identity/oauth2/token?api-version=2020-06-01&resource=https://management.azure.com/" `
		-Headers @{ Metadata = "true" } `
		-UseBasicParsing
	$token = ($imdsResponse.Content | ConvertFrom-Json).access_token
	Write-Host "Token erhalten." -ForegroundColor Green
}
catch {
	Write-Error "Fehler beim Token-Abruf. Läuft dieses Script auf einem Arc-joined Server?"
	Write-Error $_.Exception.Message
	exit 1
}

$headers = @{
	Authorization  = "Bearer $token"
	"Content-Type" = "application/json"
}

# ── Tabellen anlegen ──────────────────────────────────────────────────────────
$baseUri = "https://management.azure.com/subscriptions/$SubscriptionId" +
		"/resourceGroups/$ResourceGroup" +
		"/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName" +
		"/tables"

$tables = @(
	@{ Name = "PingCastle_Summary_CL";  File = "table_PingCastle_Summary_CL.json"  },
	@{ Name = "PingCastle_Findings_CL"; File = "table_PingCastle_Findings_CL.json" }
)

foreach ($table in $tables) {
	$jsonPath = Join-Path $scriptDir $table.File

	if (-not (Test-Path $jsonPath)) {
		Write-Error "JSON-Datei nicht gefunden: $jsonPath"
		continue
	}

	$body = Get-Content $jsonPath -Raw -Encoding UTF8
	$uri  = "$baseUri/$($table.Name)?api-version=$ApiVersion"

	Write-Host "`nErstelle Tabelle: $($table.Name)..." -ForegroundColor Cyan

	try {
		$response = Invoke-RestMethod -Uri $uri -Method PUT -Headers $headers -Body $body
		Write-Host "  OK: $($table.Name) angelegt." -ForegroundColor Green
		Write-Host "  Retention: $($response.properties.retentionInDays) Tage" -ForegroundColor Gray
	}
	catch {
		$statusCode = $_.Exception.Response.StatusCode.value__
		Write-Error "  FEHLER ($statusCode): $($_.Exception.Message)"

		# Detaillierten Fehlertext ausgeben
		if ($_.ErrorDetails.Message) {
			$errDetail = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
			if ($errDetail.error.message) {
				Write-Error "  Detail: $($errDetail.error.message)"
			}
		}
	}
}

Write-Host "`n=== Fertig ===" -ForegroundColor Cyan
Write-Host "Tabellen im Azure Portal prüfen:"
Write-Host "  Log Analytics Workspace '$WorkspaceName' → Tables → Filter: Custom" -ForegroundColor Gray
