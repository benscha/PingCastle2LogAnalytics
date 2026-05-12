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
