[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$runtime = Join-Path $env:LOCALAPPDATA 'TapSnap/formula-runtime'
$python = Join-Path $runtime 'Scripts/python.exe'
$resources = $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $resources 'formula-models.json'))) {
    $resources = (Resolve-Path (Join-Path $PSScriptRoot '../../../Resources')).Path
}
if (-not (Test-Path -LiteralPath $python)) {
    & py -3.12 -m venv $runtime
    if ($LASTEXITCODE -ne 0) { throw 'Install Python 3.12 and make the py launcher available.' }
}
& $python -m pip install 'pix2tex==0.1.4'
if ($LASTEXITCODE -ne 0) { throw 'Failed to install the offline formula recognition dependencies.' }
$modelPath = & $python -c 'import pathlib, pix2tex; print(pathlib.Path(pix2tex.__file__).parent / ''model'' / ''checkpoints'')'
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $modelPath)) { throw 'Could not locate the model directory.' }
$hashes = Get-Content -LiteralPath (Join-Path $resources 'formula-models.json') -Raw | ConvertFrom-Json
$release = 'https://github.com/lukas-blecher/LaTeX-OCR/releases/download/v0.0.1'
foreach ($model in $hashes.PSObject.Properties) {
    $installed = Join-Path $modelPath $model.Name
    if ((Test-Path -LiteralPath $installed) -and ((Get-FileHash -LiteralPath $installed).Hash -eq $model.Value)) { continue }
    $staged = "$installed.$([guid]::NewGuid().ToString('N')).download"
    try {
        Invoke-WebRequest -Uri "$release/$($model.Name)" -OutFile $staged -UseBasicParsing
        if ((Get-FileHash -LiteralPath $staged).Hash -ne $model.Value) { throw "Unexpected SHA-256 for $($model.Name)" }
        Move-Item -LiteralPath $staged -Destination $installed -Force
    } finally {
        if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged -Force }
    }
}
$env:HF_HUB_OFFLINE = '1'
$env:NO_ALBUMENTATIONS_UPDATE = '1'
& $python -c 'from pix2tex.cli import LatexOCR; LatexOCR()'
if ($LASTEXITCODE -ne 0) { throw 'Failed to prepare the model weights.' }
Write-Output "TapSnap formula recognition is ready at $runtime."
