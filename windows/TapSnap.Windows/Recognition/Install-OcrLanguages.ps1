[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$destination = Join-Path $env:LOCALAPPDATA 'TapSnap/tessdata'
$baseUrl = 'https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/4.1.0'
$packages = @{
    'eng.traineddata' = '7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2'
    'chi_sim.traineddata' = 'a5fcb6f0db1e1d6d8522f39db4e848f05984669172e584e8d76b6b3141e1f730'
}
New-Item -ItemType Directory -Force -Path $destination | Out-Null
foreach ($name in $packages.Keys) {
    $current = Join-Path $destination $name
    if ((Test-Path -LiteralPath $current) -and
        ((Get-FileHash -LiteralPath $current -Algorithm SHA256).Hash -eq $packages[$name])) { continue }
    $download = Join-Path $destination "$name.$([guid]::NewGuid().ToString('N')).download"
    try {
        Invoke-WebRequest -Uri "$baseUrl/$name" -OutFile $download -UseBasicParsing
        if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $packages[$name]) {
            throw "Unexpected SHA-256 for $name"
        }
        Move-Item -LiteralPath $download -Destination $current -Force
    } finally {
        if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download -Force }
    }
}
Write-Output "TapSnap OCR language data is ready at $destination."
