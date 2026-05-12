# PingCastle2LogAnalytics

Automated pipeline that runs PingCastle Active Directory health checks against one or more domains, parses the XML output, and ships structured data to Azure Log Analytics via the Log Ingestion API.
Most organisations run PingCastle manually and review the HTML report in isolation. This project turns those snapshots into a continuous time-series stored in Log Analytics, which unlocks three things that a standalone report cannot provide:

Multi-domain visibility — scan all your domains in a single run and compare scores, findings, and account statistics side by side in one dashboard, without opening multiple HTML files.
Trend analysis — because every scan writes a new row, you can chart how your GlobalScore, MaturityLevel, or any other metric evolves over weeks and months and immediately see whether remediations are having the desired effect.
Automated alerting — define Microsoft Sentinel analytics rules or Azure Monitor alert rules that fire when a score increases, a new Critical finding appears, or a key indicator changes (e.g. MachineAccountQuota is no longer 0, or a new domain is discovered). Your team gets notified without anyone having to remember to run a manual check.

---

## Architecture

```
Azure Arc-joined Server
│
├── generateReports.ps1
│   │
│   ├── 1. Arc IMDS (port 40342)
│   │       └── OAuth2 token for Key Vault (challenge-response)
│   │
│   ├── 2. Azure Key Vault
│   │       └── Load certificate (PFX) for App Registration
│   │
│   ├── 3. Azure AD token endpoint
│   │       └── JWT client assertion → Ingestion API token
│   │
│   ├── 4. PingCastle.exe --healthcheck (per domain)
│   │       └── ad_hc_<domain>.xml
│   │
│   └── 5. Log Ingestion API (DCE → DCR)
│           ├── PingCastle_Summary_CL   (1 row per domain/scan)
│           └── PingCastle_Findings_CL  (1 row per finding with Points > 0)
│
Azure Log Analytics Workspace
├── PingCastle_Summary_CL
└── PingCastle_Findings_CL
```

**Authentication flow (no secrets stored on disk):**
- The Arc server's **System-assigned Managed Identity** reads the certificate from Key Vault
- The certificate authenticates the **App Registration** against the Log Ingestion API via a signed JWT
- No passwords or client secrets anywhere

---

## Prerequisites

| Component | Notes |
|-----------|-------|
| PingCastle | v3.x — must be reachable from the Arc server |
| Azure Arc-joined server | System-assigned Managed Identity must be enabled |
| `himds` service | Must be running (`Get-Service himds`) |
| PowerShell | 5.1 or 7.x |
| Azure Log Analytics Workspace | Any SKU |
| Azure Key Vault | Azure RBAC access model |
| App Registration | Certificate-based auth only (no client secret) |
| Data Collection Endpoint (DCE) | Same region as Log Analytics Workspace |
| Two Data Collection Rules (DCR) | One for Summary, one for Findings |

---

## Azure Setup

### Step 1 — App Registration

1. Azure Portal → **Azure Active Directory** → **App registrations** → **New registration**
2. Name: e.g. `app-pingcastle-logingest`
3. Supported account types: **Single tenant**
4. Click **Register**
5. Note the **Application (client) ID** and **Directory (tenant) ID** — you will need them in `config.json`

> Do **not** create a client secret. Authentication is done exclusively via certificate.

---

### Step 2 — Key Vault Certificate

**2a. Create the certificate in Key Vault**

→ Key Vault → **Certificates** → **Generate/Import**

| Field | Value |
|-------|-------|
| Method | Generate |
| Certificate name | `pingcastle-logingest` (or any name — must match `config.json`) |
| Type of CA | Self-signed certificate |
| Subject | `CN=pingcastle-logingest` |
| Content type | **PKCS #12** ← required |
| Exportable private key | **Yes** ← required |
| Validity (months) | 12–24 |

After creation, verify that a matching entry appears under **Key Vault → Secrets** (same name). This secret contains the PFX and is what the script reads at runtime.

**2b. Upload the public key to the App Registration**

→ Key Vault → Certificates → `pingcastle-logingest` → current version → **Download in CER format**

→ App Registration → **Certificates & secrets** → **Certificates** → **Upload certificate** → select the `.cer` file

---

### Step 3 — Log Analytics Custom Tables

The two tables must exist before data can be ingested. Use `createTables.ps1` (requires the Arc server's Managed Identity to have **Log Analytics Contributor** on the workspace, or run it manually with your own credentials).

Fill in the four variables at the top of `createTables.ps1`:

```powershell
$SubscriptionId  = "<your-subscription-id>"
$ResourceGroup   = "<your-resource-group>"
$WorkspaceName   = "<your-log-analytics-workspace-name>"
```

Then run:
```powershell
.\createTables.ps1
```

This creates `PingCastle_Summary_CL` and `PingCastle_Findings_CL` with the full column schema. Retention is set to 90 days (interactive) / 365 days (total).

---

### Step 4 — Data Collection Endpoint (DCE)

→ Azure Portal → **Monitor** → **Data Collection Endpoints** → **Create**

| Field | Value |
|-------|-------|
| Name | any, e.g. `dce-pingcastle` |
| Region | same region as your Log Analytics Workspace |

Note the **Logs Ingestion URL** (format: `https://<name>.<region>.ingest.monitor.azure.com`).

---

### Step 5 — Data Collection Rules (DCR)

Create **two** DCRs — one for the Summary table, one for the Findings table. For each:

→ **Monitor** → **Data Collection Rules** → **Create**

| Field | Value |
|-------|-------|
| Rule name | e.g. `dcr-pingcastle-summary` / `dcr-pingcastle-findings` |
| Region | same region as workspace |
| Platform type | Windows |

**Resources tab:** skip (no agent needed — we use the Log Ingestion API)

**Collect and deliver tab:**
- Add data source → type: **Custom Text Logs (via API)**
- Stream name: `Custom-PingCastle_Summary_CL` (or `Custom-PingCastle_Findings_CL`)
- Destination: your Log Analytics Workspace → table `PingCastle_Summary_CL` (or `_Findings_CL`)

After creation, note the **Immutable ID** of each DCR (format: `dcr-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`).

---

### Step 6 — RBAC Permissions

| Identity | Resource | Role |
|----------|----------|------|
| Arc server Managed Identity | Key Vault | **Key Vault Secrets User** |
| App Registration | DCR (Summary) | **Monitoring Metrics Publisher** |
| App Registration | DCR (Findings) | **Monitoring Metrics Publisher** |

> **Key Vault access model:** this solution requires Key Vault to be configured with **Azure role-based access control** (not Vault access policy). Check under Key Vault → **Access configuration**.

> Role assignments can take up to 10 minutes to propagate.

---

## Repository Structure

```
PingCastle2LogAnalytics/
├── generateReports.ps1              # Main script
├── createTables.ps1                 # One-time table creation
├── config.json                      # Configuration (fill in your values)
├── table_PingCastle_Summary_CL.json # Table schema for REST API
└── table_PingCastle_Findings_CL.json
└── SentinelWorkbook.json
```

---

## Configuration

Copy `config.json` and fill in your values:

```json
{
    "Domains": [
        "domain1.corp.example.com",
        "domain2.corp.example.com"
    ],
    "PingCastlePath": "C:\\Tools\\PingCastle\\PingCastle.exe",

    "AzureUpload": {
        "TenantId":        "<your-tenant-id>",
        "ClientId":        "<app-registration-client-id>",
        "KeyVaultUrl":     "https://<your-keyvault-name>.vault.azure.net",
        "CertificateName": "<certificate-name-in-keyvault>",
        "DceIngestionUrl": "https://<dce-name>.<region>.ingest.monitor.azure.com",
        "DcrSummaryId":    "dcr-<immutable-id-of-summary-dcr>",
        "DcrFindingsId":   "dcr-<immutable-id-of-findings-dcr>"
    }
}
```

`PingCastlePath` can be an absolute path or relative to the script directory.

---

## Running

```powershell
cd <script-directory>
.\generateReports.ps1
```

Expected output on first successful run:

```
=== Azure Authentication ===
  Requesting Key Vault token (Arc Managed Identity)...
  Key Vault token received.
  Loading certificate 'pingcastle-logingest' from Key Vault...
  Certificate loaded: CN=pingcastle-logingest
  Valid until: ...
  Building JWT client assertion...
  Requesting ingestion token (certificate auth)...
  Ingestion token received.
=== Authentication successful ===

--- Domain: domain1.corp.example.com ---
  Running PingCastle healthcheck...
  XML: ad_hc_domain1.corp.example.com.xml
  Summary JSON created:  ad_hc_domain1.corp.example.com_summary.json
  Findings JSON created: ad_hc_domain1.corp.example.com_findings.json (23 findings)
  Uploading to Log Analytics...
    Upload OK: Custom-PingCastle_Summary_CL
    Upload OK: Custom-PingCastle_Findings_CL

=== All domains processed ===
```

Data is visible in Log Analytics after ~5 minutes:

```kql
PingCastle_Summary_CL
| sort by TimeGenerated desc

PingCastle_Findings_CL
| where Severity == "Critical"
| sort by TimeGenerated desc, Points desc
```

---

## Scheduling

Run via Windows Task Scheduler on the Arc-joined server. Recommended: weekly or daily.

```powershell
$action  = New-ScheduledTaskAction -Execute "powershell.exe" `
               -Argument "-NonInteractive -ExecutionPolicy Bypass -File `"D:\Scripts\PingCastle2LogAnalytics\generateReports.ps1`""
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 02:00
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2)
Register-ScheduledTask -TaskName "PingCastle2LogAnalytics" `
    -Action $action -Trigger $trigger -Settings $settings `
    -RunLevel Highest -User "SYSTEM"
```

---

## Log Analytics Table Schema

### PingCastle_Summary_CL

One row per domain per scan. Key columns:

| Column | Type | Description |
|--------|------|-------------|
| TimeGenerated | datetime | Scan timestamp |
| DomainFQDN | string | e.g. `corp.example.com` |
| GlobalScore | int | Overall risk score (0–100, higher = worse) |
| StaleObjectsScore | int | Stale Objects category score |
| PrivilegiedGroupScore | int | Privileged Groups category score |
| TrustScore | int | Trusts category score |
| AnomalyScore | int | Anomalies category score |
| MaturityLevel | int | Maturity level 1–5 |
| FindingsCount_Critical | int | Findings with ≥ 15 points |
| FindingsCount_High | int | Findings with 10–14 points |
| FindingsCount_Medium | int | Findings with 5–9 points |
| FindingsCount_Low | int | Findings with 1–4 points |
| KrbtgtLastChangeDate | datetime | Last KRBTGT password rotation |
| MachineAccountQuota | int | Should be 0 |
| LAPSInstalled | bool | Legacy LAPS deployed |
| NewLAPSInstalled | bool | Windows LAPS (2023) deployed |

Full schema: see `table_PingCastle_Summary_CL.json`

### PingCastle_Findings_CL

One row per active finding (Points > 0) per domain per scan.

| Column | Type | Description |
|--------|------|-------------|
| TimeGenerated | datetime | Scan timestamp |
| DomainFQDN | string | Domain |
| RiskId | string | Unique finding ID, e.g. `A-DC-Spooler` |
| Category | string | `StaleObjects` / `Anomalies` / `Trusts` / `PrivilegedAccounts` |
| Points | int | Risk score of this finding |
| Severity | string | `Critical` / `High` / `Medium` / `Low` |
| Rationale | string | Description of the finding |
| Details | string | Additional technical details |

---

## Sentinel Workbook
- Create a New Workbook and import the SentinelWorkbook.json

<img width="784" height="1354" alt="Gemini_Generated_Image_svbbpisvbbpisvbb" src="https://github.com/user-attachments/assets/0f674225-4227-4fde-ad82-54986f406788" />


---

## Troubleshooting

### `Arc IMDS: No WWW-Authenticate header received`
The `himds` service is not running or the endpoint is unreachable.
```powershell
Get-Service himds
# Should be: Running
Test-NetConnection -ComputerName localhost -Port 40342
```

### `Arc IMDS: Step 3 failed: 401 Unauthorized`
The challenge token was rejected. Common causes:
- Arc server has no System-assigned Managed Identity enabled (check Azure Portal → Azure Arc → Servers → `<server>` → Identity)
- The `himds` service was just restarted; wait 30 seconds and retry

### `Key Vault: 404 Not Found`
- Certificate name in `config.json` does not match the name in Key Vault
- The certificate was created without **Exportable private key** → no secret is auto-generated
- The secret exists but the Arc MI does not have **Key Vault Secrets User** role (check IAM, wait up to 10 minutes for propagation)
- Key Vault uses **Vault access policy** model instead of Azure RBAC → add an Access Policy for the Arc MI with `Get` on Secrets

### `Failed to get ingestion token: 401 Unauthorized`
- The certificate uploaded to the App Registration (`.cer`) does not match the certificate currently in Key Vault
- The JWT `x5t` thumbprint doesn't match → re-download the `.cer` from Key Vault and re-upload to the App Registration

### `Upload ERROR [403]`
The App Registration is missing **Monitoring Metrics Publisher** role on the DCR.
→ DCR → Access control (IAM) → Add role assignment → `Monitoring Metrics Publisher` → assign to the App Registration

### Data not appearing in Log Analytics
- New tables and DCRs can take up to 15 minutes before the first row is queryable
- Verify the stream name in the DCR exactly matches `Custom-PingCastle_Summary_CL` / `Custom-PingCastle_Findings_CL`
- Check the DCR's Immutable ID in the portal matches `config.json`

---

## Security Notes

- No credentials are stored on disk. The only secret material is the private key inside Key Vault, readable only by the Arc server's Managed Identity.
- The Arc IMDS challenge-response mechanism proves local execution: the `.key` file in `C:\ProgramData\AzureConnectedMachineAgent\Tokens\` is only accessible to processes running on the Arc machine.
- The App Registration has no client secret and no permissions beyond `Monitoring Metrics Publisher` on the two DCRs.
- Certificate expiry is checked at runtime; a warning is logged 30 days before expiry.

---

## known Bugs 🪳

- The Details Field shows only square brackets 😵‍💫 i recommend to Transform this Field away in your DCR
- | project-away Details

---

## Scripts

### `generateReports.ps1`

```powershell
# =============================================================================
# generateReports.ps1
# PingCastle Healthcheck -> JSON Export -> Log Analytics Upload
#
# Authentication:
#   Arc Managed Identity  -> Key Vault (read certificate)
#   app-scr-pingcastlelogingest (App Registration) -> Log Ingestion API (Cert-JWT)
#
# Output per domain:
#   ad_hc_<domain>_summary.json   -> PingCastle_Summary_CL
#   ad_hc_<domain>_findings.json  -> PingCastle_Findings_CL
# =============================================================================

# ---------------------------------------------------------------------------
# HELPER FUNCTIONS
# ---------------------------------------------------------------------------

function Get-ArcManagedIdentityToken {
    <#
    .SYNOPSIS
        Retrieves an OAuth2 token from the Azure Arc IMDS endpoint (port 40342).
        Arc uses a challenge-response mechanism:
          1. GET -> 401 + WWW-Authenticate header containing path to a local key file
                    Format: Basic realm=<filepath>  (no quotes around path)
          2. Read the key file (only possible locally = proof of local execution)
          3. GET + Authorization: Basic <Base64(key)> -> access_token
        Uses HttpWebRequest instead of Invoke-WebRequest to reliably access
        response headers from error responses (PS5.1 + PS7 compatible).
    #>
    param([string]$Resource)

    $uri = "http://localhost:40342/metadata/identity/oauth2/token" +
           "?api-version=2020-06-01&resource=$Resource"

    # -- Step 1: Challenge request -------------------------------------------
    $req1 = [System.Net.HttpWebRequest]::Create($uri)
    $req1.Headers.Add("Metadata", "true")
    $req1.Method = "GET"

    $wwwAuth = $null
    try {
        # Some Arc versions return a token directly without a challenge
        $resp1  = $req1.GetResponse()
        $reader = [System.IO.StreamReader]::new($resp1.GetResponseStream())
        return ($reader.ReadToEnd() | ConvertFrom-Json).access_token
    }
    catch {
        # PowerShell wraps .NET exceptions in MethodInvocationException.
        # The real WebException lives in InnerException — unwrap it.
        $webEx    = $_.Exception.InnerException -as [System.Net.WebException]
        if (-not $webEx) { $webEx = $_.Exception -as [System.Net.WebException] }
        $httpResp = if ($webEx) { $webEx.Response -as [System.Net.HttpWebResponse] } else { $null }

        if ($null -ne $httpResp) {
            $wwwAuth = $httpResp.Headers['WWW-Authenticate']
        }
        if (-not $wwwAuth) {
            $errBody = ""
            if ($httpResp) {
                try {
                    $errBody = [System.IO.StreamReader]::new($httpResp.GetResponseStream()).ReadToEnd()
                } catch {}
            }
            throw "Arc IMDS: No WWW-Authenticate header received. Error: $($_.Exception.Message) | Body: $errBody"
        }
    }

    # -- Step 2: Extract key file path and read key --------------------------
    # WWW-Authenticate format used by Arc:
    #   Basic realm=C:\ProgramData\AzureConnectedMachineAgent\Tokens\<guid>.key
    # Note: path is NOT quoted - try both quoted and unquoted patterns
    $keyFile = [regex]::Match($wwwAuth, 'realm="([^"]+)"').Groups[1].Value
    if (-not $keyFile) {
        $keyFile = [regex]::Match($wwwAuth, 'realm=([^\s,]+)').Groups[1].Value
    }
    if (-not $keyFile) {
        $keyFile = [regex]::Match($wwwAuth, 'filename="([^"]+)"').Groups[1].Value
    }
    if (-not $keyFile) {
        $keyFile = [regex]::Match($wwwAuth, 'filename=([^\s,]+)').Groups[1].Value
    }
    if (-not $keyFile) {
        throw "Arc IMDS: Could not parse key file path from WWW-Authenticate: $wwwAuth"
    }
    if (-not (Test-Path $keyFile)) {
        throw "Arc IMDS: Key file not found: $keyFile"
    }

    # The .key file already contains a Base64-encoded challenge token.
    # Use the file content directly as the Basic auth credential — do NOT re-encode.
    $encoded = ([System.IO.File]::ReadAllText($keyFile)).Trim()

    # -- Step 3: Authenticated token request ---------------------------------
    try {
        $req2 = [System.Net.HttpWebRequest]::Create($uri)
        $req2.Headers.Add("Metadata",      "true")
        $req2.Headers.Add("Authorization", "Basic $encoded")
        $req2.Method = "GET"

        $resp2  = $req2.GetResponse()
        $reader = [System.IO.StreamReader]::new($resp2.GetResponseStream())
        return ($reader.ReadToEnd() | ConvertFrom-Json).access_token
    }
    catch {
        $webEx3    = $_.Exception.InnerException -as [System.Net.WebException]
        if (-not $webEx3) { $webEx3 = $_.Exception -as [System.Net.WebException] }
        $httpResp3 = if ($webEx3) { $webEx3.Response -as [System.Net.HttpWebResponse] } else { $null }
        $errBody3  = ""
        if ($httpResp3) {
            try {
                $errBody3 = [System.IO.StreamReader]::new($httpResp3.GetResponseStream()).ReadToEnd()
            } catch {}
        }
        throw "Arc IMDS: Step 3 failed: $($_.Exception.Message) | Body: $errBody3"
    }
}

function ConvertTo-Base64Url {
    param([string]$Text)
    [Convert]::ToBase64String(
        [System.Text.Encoding]::UTF8.GetBytes($Text)
    ) -replace '\+', '-' -replace '/', '_' -replace '=', ''
}

function Send-ToLogAnalytics {
    param(
        [string]$JsonFilePath,
        [string]$DceUrl,
        [string]$DcrImmutableId,
        [string]$StreamName,
        [string]$BearerToken
    )
    $body    = Get-Content $JsonFilePath -Raw -Encoding UTF8
    $headers = @{
        'Authorization' = "Bearer $BearerToken"
        'Content-Type'  = 'application/json'
    }
    $uri = "$DceUrl/dataCollectionRules/$DcrImmutableId/streams/$StreamName" +
           '?api-version=2023-01-01'
    try {
        Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $body | Out-Null
        Write-Host "    Upload OK: $StreamName" -ForegroundColor Green
    }
    catch {
        $code = $_.Exception.Response.StatusCode.value__
        Write-Error "    Upload ERROR [$code] $StreamName : $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 1. CONFIGURATION
# ---------------------------------------------------------------------------
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $scriptDir

$configPath = Join-Path $scriptDir "config.json"
if (-not (Test-Path $configPath)) {
    Write-Error "config.json not found: $configPath"
    exit 1
}

$config = Get-Content $configPath | ConvertFrom-Json

# PingCastle path: use absolute path directly, resolve relative path against script directory
if ([System.IO.Path]::IsPathRooted($config.PingCastlePath)) {
    $executable = $config.PingCastlePath
} else {
    $executable = Join-Path $scriptDir $config.PingCastlePath
}

if (-not (Test-Path $executable)) {
    Write-Error "PingCastle.exe not found: $executable"
    exit 1
}

$az = $config.AzureUpload

# ---------------------------------------------------------------------------
# 2. AZURE AUTHENTICATION (once, before the domain loop)
# ---------------------------------------------------------------------------
Write-Host "`n=== Azure Authentication ===" -ForegroundColor Cyan

# 2a. Arc Managed Identity: token for Key Vault (challenge-response)
Write-Host "  Requesting Key Vault token (Arc Managed Identity)..." -ForegroundColor Gray
try {
    $kvToken = Get-ArcManagedIdentityToken -Resource "https://vault.azure.net"
    Write-Host "  Key Vault token received." -ForegroundColor Green

    # Decode JWT payload to verify which identity the token belongs to
    $parts   = $kvToken.Split('.')
    $pad     = 4 - ($parts[1].Length % 4); if ($pad -lt 4) { $b64 = $parts[1] + ('=' * $pad) } else { $b64 = $parts[1] }
    $b64     = $b64 -replace '-','+' -replace '_','/'
    $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json
    Write-Host "  [DEBUG] Token aud : $($decoded.aud)"  -ForegroundColor Magenta
    Write-Host "  [DEBUG] Token oid : $($decoded.oid)"  -ForegroundColor Magenta
    Write-Host "  [DEBUG] Token xms_mirid: $($decoded.xms_mirid)" -ForegroundColor Magenta
}
catch {
    Write-Error "Failed to get Key Vault token (Arc IMDS): $($_.Exception.Message)"
    Write-Error "Check: Arc-joined server? himds service running? Managed Identity enabled?"
    exit 1
}

# 2b. Load certificate (PFX incl. private key) from Key Vault
Write-Host "  Loading certificate '$($az.CertificateName)' from Key Vault..." -ForegroundColor Gray
try {
    $secretUri  = "$($az.KeyVaultUrl.TrimEnd('/'))/secrets/$($az.CertificateName)?api-version=7.4"
    Write-Host "  [DEBUG] Secret URI: $secretUri" -ForegroundColor Magenta
    $secretResp = Invoke-RestMethod `
        -Uri $secretUri `
        -Headers @{ Authorization = "Bearer $kvToken" } `
        -ErrorAction Stop

    $certBytes = [Convert]::FromBase64String($secretResp.value)
    $flags     = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable -bor
                 [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet
    $cert      = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $certBytes, "", $flags
    )
    Write-Host "  Certificate loaded: $($cert.Subject)" -ForegroundColor Green
    Write-Host "  Valid until:        $($cert.GetExpirationDateString())" -ForegroundColor Gray

    if ($cert.NotAfter -lt (Get-Date).AddDays(30)) {
        Write-Warning "Certificate expires in less than 30 days! Please renew."
    }
}
catch {
    Write-Error "Failed to load certificate from Key Vault: $($_.Exception.Message)"
    exit 1
}

# 2c. Build and sign JWT client assertion
Write-Host "  Building JWT client assertion (app-scr-pingcastlelogingest)..." -ForegroundColor Gray

$now = [DateTimeOffset]::UtcNow
$exp = $now.AddMinutes(10).ToUnixTimeSeconds()
$nbf = $now.ToUnixTimeSeconds()

# x5t: SHA-1 thumbprint of certificate as Base64Url
$thumbBytes = [byte[]]($cert.Thumbprint -split '(..)' |
    Where-Object { $_ } |
    ForEach-Object { [Convert]::ToByte($_, 16) })
$x5t = ([Convert]::ToBase64String($thumbBytes)) -replace '\+', '-' -replace '/', '_' -replace '=', ''

$jwtHeader  = "{`"alg`":`"RS256`",`"typ`":`"JWT`",`"x5t`":`"$x5t`"}"
$jwtPayload = "{" +
    "`"aud`":`"https://login.microsoftonline.com/$($az.TenantId)/oauth2/v2.0/token`"," +
    "`"exp`":$exp," +
    "`"iss`":`"$($az.ClientId)`"," +
    "`"jti`":`"$([System.Guid]::NewGuid().ToString())`"," +
    "`"nbf`":$nbf," +
    "`"sub`":`"$($az.ClientId)`"" +
    "}"

$sigInput = "$(ConvertTo-Base64Url $jwtHeader).$(ConvertTo-Base64Url $jwtPayload)"

# GetRSAPrivateKey() is a C# extension method — must be called as static method in PowerShell
# This works for both CNG keys (Key Vault) and legacy CSP keys
$rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
if ($null -eq $rsa) {
    # Fallback for legacy CSP keys
    $rsa = $cert.PrivateKey -as [System.Security.Cryptography.RSACryptoServiceProvider]
}
if ($null -eq $rsa) {
    throw "Certificate private key is not accessible. Check Exportable flag and certificate format."
}

if ($rsa -is [System.Security.Cryptography.RSACryptoServiceProvider]) {
    # Legacy CSP path
    $sigBytes = $rsa.SignData(
        [System.Text.Encoding]::ASCII.GetBytes($sigInput),
        [System.Security.Cryptography.CryptoConfig]::MapNameToOID("SHA256")
    )
} else {
    # CNG path (RSACng) — supports the modern API
    $sigBytes = $rsa.SignData(
        [System.Text.Encoding]::ASCII.GetBytes($sigInput),
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
    )
}
$sig = ([Convert]::ToBase64String($sigBytes)) -replace '\+', '-' -replace '/', '_' -replace '=', ''
$jwt = "$sigInput.$sig"

# 2d. Get access token for Log Ingestion API
Write-Host "  Requesting ingestion token (certificate auth)..." -ForegroundColor Gray
try {
    $tokenBody = @{
        grant_type            = "client_credentials"
        client_id             = $az.ClientId
        client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
        client_assertion      = $jwt
        scope                 = "https://monitor.azure.com/.default"
    }
    $ingestionToken = (Invoke-RestMethod `
        -Uri "https://login.microsoftonline.com/$($az.TenantId)/oauth2/v2.0/token" `
        -Method POST `
        -Body $tokenBody `
        -ErrorAction Stop).access_token
    Write-Host "  Ingestion token received." -ForegroundColor Green
}
catch {
    Write-Error "Failed to get ingestion token: $($_.Exception.Message)"
    exit 1
}

Write-Host "=== Authentication successful ===" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 3. PER DOMAIN: RUN PINGCASTLE, CREATE JSON, UPLOAD
# ---------------------------------------------------------------------------
foreach ($domain in $config.Domains) {
    Write-Host "`n--- Domain: $domain ---" -ForegroundColor Cyan

    # 3a. Run PingCastle
    Write-Host "  Running PingCastle healthcheck..." -ForegroundColor Gray
    & $executable --healthcheck --server $domain --no-enum-limit --level Full

    # 3b. Find most recent XML for this domain
    $xmlFile = Get-ChildItem -Path $scriptDir -Filter "*$($domain)*.xml" |
               Sort-Object LastWriteTime -Descending |
               Select-Object -First 1

    if (-not $xmlFile) {
        Write-Warning "No XML found for $domain - skipping."
        continue
    }
    Write-Host "  XML: $($xmlFile.Name)" -ForegroundColor Gray

    try {
        [xml]$xmlData = Get-Content $xmlFile.FullName -Encoding UTF8
        $hc        = $xmlData.HealthcheckData
        $baseName  = $xmlFile.FullName -replace '\.xml$', ''
        $scanDate  = $hc.GenerationDate

        # -------------------------------------------------------------------
        # 3c. SUMMARY - one object per domain/scan
        # -------------------------------------------------------------------
        $summary = [PSCustomObject]@{

            # Metadata
            TimeGenerated                  = $scanDate
            DomainFQDN                     = $hc.DomainFQDN
            NetBIOSName                    = $hc.NetBIOSName
            ForestFQDN                     = $hc.ForestFQDN
            DomainSid                      = $hc.DomainSid
            DomainCreation                 = $hc.DomainCreation
            EngineVersion                  = $hc.EngineVersion
            ScanLevel                      = $hc.Level

            # Scores
            GlobalScore                    = [int]$hc.GlobalScore
            StaleObjectsScore              = [int]$hc.StaleObjectsScore
            PrivilegiedGroupScore          = [int]$hc.PrivilegiedGroupScore
            TrustScore                     = [int]$hc.TrustScore
            AnomalyScore                   = [int]$hc.AnomalyScore
            MaturityLevel                  = [int]$hc.MaturityLevel

            # Domain structure
            NumberOfDC                     = [int]$hc.NumberOfDC
            DomainFunctionalLevel          = [int]$hc.DomainFunctionalLevel
            ForestFunctionalLevel          = [int]$hc.ForestFunctionalLevel
            SchemaVersion                  = [int]$hc.SchemaVersion

            # Security indicators
            KrbtgtLastChangeDate           = $hc.KrbtgtLastChangeDate
            KrbtgtLastVersion              = [int]$hc.KrbtgtLastVersion
            MachineAccountQuota            = [int]$hc.MachineAccountQuota
            GuestEnabled                   = ($hc.GuestEnabled -eq 'true')
            IsRecycleBinEnabled            = ($hc.IsRecycleBinEnabled -eq 'true')
            IsPrivilegedMode               = ($hc.IsPrivilegedMode -eq 'true')
            UsingNTFRSForSYSVOL            = ($hc.UsingNTFRSForSYSVOL -eq 'true')
            ExchangePrivEscVulnerable      = ($hc.ExchangePrivEscVulnerable -eq 'true')
            PreWindows2000AnonymousAccess  = ($hc.PreWindows2000AnonymousAccess -eq 'true')
            AdminSDHolderNotOKCount        = [int]$hc.AdminSDHolderNotOKCount
            SIDHistoryAuditingGroupPresent = ($hc.SIDHistoryAuditingGroupPresent -eq 'true')
            AdminLastLoginDate             = $hc.AdminLastLoginDate
            AdminAccountName               = $hc.AdminAccountName
            LastADBackup                   = $hc.LastADBackup
            LAPSInstalled                  = ($null -ne $hc.LAPSInstalled -and $hc.LAPSInstalled -ne '')
            NewLAPSInstalled               = ($null -ne $hc.NewLAPSInstalled -and $hc.NewLAPSInstalled -ne '')
            SCCMInstalled                  = ($null -ne $hc.SCCMInstalled -and $hc.SCCMInstalled -ne '')
            HasKdsRootKey                  = ($hc.HasKdsRootKey -eq 'true')

            # User statistics
            Users_Total                    = [int]$hc.UserAccountData.Number
            Users_Enabled                  = [int]$hc.UserAccountData.NumberEnabled
            Users_Disabled                 = [int]$hc.UserAccountData.NumberDisabled
            Users_Active                   = [int]$hc.UserAccountData.NumberActive
            Users_Inactive                 = [int]$hc.UserAccountData.NumberInactive
            Users_Locked                   = [int]$hc.UserAccountData.NumberLocked
            Users_PwdNeverExpires          = [int]$hc.UserAccountData.NumberPwdNeverExpires
            Users_PwdNotRequired           = [int]$hc.UserAccountData.NumberPwdNotRequired
            Users_NotAesEnabled            = [int]$hc.UserAccountData.NumberNotAesEnabled
            Users_ReversibleEncryption     = [int]$hc.UserAccountData.NumberReversibleEncryption
            Users_NoPreAuth                = [int]$hc.UserAccountData.NumberNoPreAuth
            Users_SidHistory               = [int]$hc.UserAccountData.NumberSidHistory
            Users_DesEnabled               = [int]$hc.UserAccountData.NumberDesEnabled

            # Computer statistics
            Computers_Total                = [int]$hc.ComputerAccountData.Number
            Computers_Enabled              = [int]$hc.ComputerAccountData.NumberEnabled
            Computers_Disabled             = [int]$hc.ComputerAccountData.NumberDisabled
            Computers_Active               = [int]$hc.ComputerAccountData.NumberActive
            Computers_Inactive             = [int]$hc.ComputerAccountData.NumberInactive
            Computers_PwdNeverExpires      = [int]$hc.ComputerAccountData.NumberPwdNeverExpires
            Computers_PwdNotRequired       = [int]$hc.ComputerAccountData.NumberPwdNotRequired
            Computers_NotAesEnabled        = [int]$hc.ComputerAccountData.NumberNotAesEnabled
            Computers_LAPS_Active          = [int]$hc.ComputerAccountData.NumberLAPSActive
            Computers_NewLAPS_Active       = [int]$hc.ComputerAccountData.NumberLAPSNewActive
            Computers_SidHistory           = [int]$hc.ComputerAccountData.NumberSidHistory
            Computers_TrustedForDelegation = [int]$hc.ComputerAccountData.NumberEnabledTrustedToAuthenticateForDelegation

            # Findings summary
            FindingsCount_Total            = ($hc.RiskRules.HealthcheckRiskRule | Where-Object { [int]$_.Points -gt 0  } | Measure-Object).Count
            FindingsCount_Critical         = ($hc.RiskRules.HealthcheckRiskRule | Where-Object { [int]$_.Points -ge 15 } | Measure-Object).Count
            FindingsCount_High             = ($hc.RiskRules.HealthcheckRiskRule | Where-Object { [int]$_.Points -ge 10 -and [int]$_.Points -lt 15 } | Measure-Object).Count
            FindingsCount_Medium           = ($hc.RiskRules.HealthcheckRiskRule | Where-Object { [int]$_.Points -ge 5  -and [int]$_.Points -lt 10 } | Measure-Object).Count
            FindingsCount_Low              = ($hc.RiskRules.HealthcheckRiskRule | Where-Object { [int]$_.Points -gt 0  -and [int]$_.Points -lt 5  } | Measure-Object).Count
        }

        $summaryJson = $baseName + "_summary.json"
        ConvertTo-Json -InputObject @($summary) -Depth 5 | Out-File $summaryJson -Encoding utf8
        Write-Host "  Summary JSON created:  $([System.IO.Path]::GetFileName($summaryJson))" -ForegroundColor White

        # -------------------------------------------------------------------
        # 3d. FINDINGS - one object per RiskRule with Points > 0
        # -------------------------------------------------------------------
        $findings = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($rule in $hc.RiskRules.HealthcheckRiskRule) {
            $points = [int]$rule.Points
            if ($points -eq 0) { continue }

            $severity = switch ($points) {
                { $_ -ge 15 } { "Critical"; break }
                { $_ -ge 10 } { "High";     break }
                { $_ -ge 5  } { "Medium";   break }
                default        { "Low" }
            }

            $findings.Add([PSCustomObject]@{
                TimeGenerated = $scanDate
                DomainFQDN    = $hc.DomainFQDN
                NetBIOSName   = $hc.NetBIOSName
                Points        = $points
                Severity      = $severity
                Category      = $rule.Category
                Model         = $rule.Model
                RiskId        = $rule.RiskId
                Rationale     = $rule.Rationale
                Details       = if ($rule.Details) { $rule.Details } else { "" }
            })
        }

        $findings     = $findings | Sort-Object Points -Descending
        $findingsJson = $baseName + "_findings.json"
        ConvertTo-Json -InputObject @($findings) -Depth 5 | Out-File $findingsJson -Encoding utf8
        Write-Host "  Findings JSON created: $([System.IO.Path]::GetFileName($findingsJson)) ($($findings.Count) findings)" -ForegroundColor White

        # -------------------------------------------------------------------
        # 3e. UPLOAD to Log Analytics
        # -------------------------------------------------------------------
        Write-Host "  Uploading to Log Analytics..." -ForegroundColor Gray

        Send-ToLogAnalytics `
            -JsonFilePath   $summaryJson `
            -DceUrl         $az.DceIngestionUrl `
            -DcrImmutableId $az.DcrSummaryId `
            -StreamName     "Custom-PingCastle_Summary_CL" `
            -BearerToken    $ingestionToken

        Send-ToLogAnalytics `
            -JsonFilePath   $findingsJson `
            -DceUrl         $az.DceIngestionUrl `
            -DcrImmutableId $az.DcrFindingsId `
            -StreamName     "Custom-PingCastle_Findings_CL" `
            -BearerToken    $ingestionToken

        # -------------------------------------------------------------------
        # 3f. ARCHIVE JSON files / CLEAN UP XML and HTML
        # -------------------------------------------------------------------
        $archiveDir = Join-Path $scriptDir "Archiv"
        if (-not (Test-Path $archiveDir)) {
            New-Item -ItemType Directory -Path $archiveDir | Out-Null
            Write-Host "  Archive folder created: $archiveDir" -ForegroundColor Gray
        }

        $datePrefix = (Get-Date).ToString("yyyyMMdd")

        $archivedSummary  = Join-Path $archiveDir ($datePrefix + "_" + [System.IO.Path]::GetFileName($summaryJson))
        $archivedFindings = Join-Path $archiveDir ($datePrefix + "_" + [System.IO.Path]::GetFileName($findingsJson))

        Move-Item -Path $summaryJson  -Destination $archivedSummary  -Force
        Move-Item -Path $findingsJson -Destination $archivedFindings -Force
        Write-Host "  JSON archived: $([System.IO.Path]::GetFileName($archivedSummary))" -ForegroundColor Gray
        Write-Host "  JSON archived: $([System.IO.Path]::GetFileName($archivedFindings))" -ForegroundColor Gray

        # Delete PingCastle XML and HTML output
        Remove-Item -Path $xmlFile.FullName -Force
        Write-Host "  Deleted: $($xmlFile.Name)" -ForegroundColor Gray

        $htmlFile = $xmlFile.FullName -replace '\.xml$', '.html'
        if (Test-Path $htmlFile) {
            Remove-Item -Path $htmlFile -Force
            Write-Host "  Deleted: $([System.IO.Path]::GetFileName($htmlFile))" -ForegroundColor Gray
        }
    }
    catch {
        Write-Error "Error processing $domain : $($_.Exception.Message)"
    }
}

Write-Host "`n=== All domains processed ===" -ForegroundColor Cyan

```

---


