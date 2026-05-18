# BitLocker-Encrypt.ps1 -> .exe derleyici
# Yonetici olarak PowerShell'de calistirin

# PS2EXE yuklu degil ise yukle
if (-not (Get-Module -ListAvailable -Name PS2EXE)) {
    Write-Host "[*] PS2EXE kuruluyor..." -ForegroundColor Cyan
    Install-Module -Name PS2EXE -Scope CurrentUser -Force
}

$scriptPath = Join-Path $PSScriptRoot "BitLocker-Encrypt.ps1"
$outputPath = Join-Path $PSScriptRoot "BitLocker-Encrypt.exe"

Write-Host "[*] Derleniyor: $scriptPath" -ForegroundColor Cyan

Invoke-PS2EXE `
    -InputFile  $scriptPath `
    -OutputFile $outputPath `
    -RequireAdmin `
    -NoConsole:$false `
    -Title   "BitLocker Sifreleme" `
    -Version "3.0.0.0"

if (Test-Path $outputPath) {
    Write-Host "[OK] EXE olusturuldu: $outputPath" -ForegroundColor Green
    Write-Host ""
    Write-Host "  !! ONEMLI: EXE olusturulduktan sonra BitLocker-Encrypt.ps1" -ForegroundColor Yellow
    Write-Host "  !! dosyasini sunucudan silin. Icinde private key var!" -ForegroundColor Yellow
} else {
    Write-Host "[XX] Derleme basarisiz." -ForegroundColor Red
}
