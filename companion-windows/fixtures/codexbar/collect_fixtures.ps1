# Nimmt die Win-CodexBar-Fixtures auf. Auf einem Windows-Rechner mit
# installiertem Win-CodexBar ausführen:
#
#   powershell -ExecutionPolicy Bypass -File collect_fixtures.ps1
#
# Schreibt je Provider die JSON-Antwort in dieses Verzeichnis, maskiert
# Konto-E-Mail und Organisation und legt die CLI-Version ab.

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$candidates = @(
  (Join-Path $env:LOCALAPPDATA "Programs\CodexBar\codexbar-cli.exe"),
  "codexbar-cli.exe"
)
$cli = $null
foreach ($c in $candidates) {
  if (Get-Command $c -ErrorAction SilentlyContinue) { $cli = $c; break }
}
if (-not $cli) { throw "codexbar-cli.exe nicht gefunden. Win-CodexBar installieren: winget install Finesssee.Win-CodexBar" }
Write-Host "CLI: $cli"

& $cli --version | Out-File -Encoding utf8 (Join-Path $here "cli-version.txt")

$providers = @("claude", "codex", "antigravity", "gemini", "copilot", "cursor")
foreach ($p in $providers) {
  $raw = & $cli usage -p $p -f json --pretty 2>&1 | Out-String
  $exit = $LASTEXITCODE
  # Konto-Daten maskieren, Struktur bleibt erhalten.
  $masked = $raw -replace '("account_email"\s*:\s*)"[^"]*"', '$1"user@example.com"' `
                 -replace '("account_organization"\s*:\s*)"[^"]*"', '$1"Example Org"'
  $suffix = if ($exit -eq 0 -and $raw -notmatch '"error"') { "" } else { "-error" }
  $path = Join-Path $here "$p$suffix.json"
  $masked | Out-File -Encoding utf8 $path
  Write-Host ("{0,-12} exit={1} -> {2}" -f $p, $exit, (Split-Path -Leaf $path))
}
Write-Host "Fertig. Dateien vor dem Commit auf weitere personenbezogene Daten prüfen."
