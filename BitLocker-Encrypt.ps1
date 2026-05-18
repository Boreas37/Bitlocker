# BitLocker Otomatik Sifreleme - TPM + Enhanced PIN
# OS surucu: TPM + PIN (her boot'ta PIN sorulur, TPM ile muhurlenir)
# Data surucu: Password + AutoUnlock (OS acilinca otomatik acilir)
# HTTP + API Key ile korunur (ic ag icin - SSL yok)
# Kurtarma anahtari korubt kullanicisinin Desktop'una yazilir (API'den bagimsiz)
# PowerShell 5.1 uyumlu - Yonetici olarak calistirilmalidir

#region Konfigurasyon

$API_BASE = "http://10.10.100.140:5000"
$API_KEY  = "6CaRqsYr7wySKpOzaWFg2OvalX1YBCXiGfC6PR4s"   # .env'deki API_KEY ile ayni olmali

#endregion

#region Fonksiyonlar

function Get-PasswordFromAPI {
    param([string]$ComputerName)

    $apiUrl  = "$API_BASE/api/bitlocker/password/$ComputerName"
    $headers = @{ "X-API-Key" = $API_KEY }

    try {
        $response = Invoke-RestMethod -Uri $apiUrl `
                                      -Method GET `
                                      -Headers $headers `
                                      -ContentType "application/json" `
                                      -TimeoutSec 15 `
                                      -UseBasicParsing

        if ($response.success -and $response.password) {
            return $response.password
        } else {
            Write-Host "  [API HATA] Sifre alinamadi: $($response.error)" -ForegroundColor DarkRed
            return $null
        }
    }
    catch {
        Write-Host "  [API HATA] Sifre endpoint'ine ulasilamadi: $($_.Exception.Message)" -ForegroundColor DarkRed
        return $null
    }
}

function Save-ToAPI {
    param(
        [string]$ComputerName,
        [string]$DriveLetter,
        [string]$Password,
        [string]$RecoveryKey
    )

    $apiUrl  = "$API_BASE/api/bitlocker"
    $headers = @{ "X-API-Key" = $API_KEY }

    $bodyObj = @{
        ComputerName      = $ComputerName
        DriveLetter       = $DriveLetter
        BitLockerPassword = $Password
        RecoveryKey       = $RecoveryKey
        Status            = "Encrypted"
    }
    $body = $bodyObj | ConvertTo-Json -Compress

    try {
        $response = Invoke-RestMethod -Uri $apiUrl `
                                      -Method POST `
                                      -Headers $headers `
                                      -Body $body `
                                      -ContentType "application/json" `
                                      -TimeoutSec 15 `
                                      -UseBasicParsing
        if ($response.success) { return $true }
        else {
            Write-Host "  [API HATA] $($response.error)" -ForegroundColor DarkRed
            return $false
        }
    }
    catch {
        Write-Host "  [API HATA] $($_.Exception.Message)" -ForegroundColor DarkRed
        return $false
    }
}

function Save-RecoveryKeyToDesktop {
    param(
        [string]$ComputerName,
        [string]$DriveLetter,
        [string]$RecoveryKey,
        [string]$Password
    )

    $desktopPath = "C:\Users\korubt\Desktop"

    if (-not (Test-Path $desktopPath)) {
        try {
            New-Item -ItemType Directory -Path $desktopPath -Force | Out-Null
        }
        catch {
            $desktopPath = "C:\Windows\Temp"
            Write-Host "  [!!] korubt Desktop'u bulunamadi, C:\Windows\Temp kullaniliyor" -ForegroundColor Yellow
        }
    }

    $safeDir   = $DriveLetter -replace ":", ""
    $fileName  = "BitLocker_${ComputerName}_${safeDir}.txt"
    $filePath  = Join-Path $desktopPath $fileName
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $content = @"
============================================
  BitLocker Kurtarma Bilgileri
============================================
Bilgisayar   : $ComputerName
Surucu       : $DriveLetter
Sifre        : $Password
Kurtarma Key : $RecoveryKey
Tarih        : $timestamp
============================================
NOT: Bu dosyayi guvenli bir yere kopyalayin.
"@

    try {
        $content | Out-File -FilePath $filePath -Encoding UTF8 -Force
        Write-Host "  [OK] Kurtarma anahtari Desktop'a yazildi: $filePath" -ForegroundColor Green
        return $filePath
    }
    catch {
        Write-Host "  [!!] Desktop'a yazilamadi: $_" -ForegroundColor Yellow
        $fallbackPath = "C:\Windows\Temp\$fileName"
        $content | Out-File -FilePath $fallbackPath -Encoding UTF8 -Force
        Write-Host "  [!!] Fallback yedek: $fallbackPath" -ForegroundColor Yellow
        return $fallbackPath
    }
}

function Show-ProgressBar {
    param(
        [int]$Percent,
        [string]$Status,
        [string]$Color = "Cyan"
    )
    $barWidth  = 40
    $filled    = [math]::Round($barWidth * $Percent / 100)
    $empty     = $barWidth - $filled
    $filledStr = ""
    $emptyStr  = ""
    for ($x = 0; $x -lt $filled; $x++) { $filledStr += "#" }
    for ($x = 0; $x -lt $empty;  $x++) { $emptyStr  += "-" }
    $bar = "[$filledStr$emptyStr]"
    Write-Host "`r  $bar $Percent%  $Status                    " -ForegroundColor $Color -NoNewline
}

function Show-StepHeader { param([string]$Title); Write-Host ""; Write-Host "  > $Title" -ForegroundColor White }
function Show-Done       { param([string]$Msg);  Write-Host ""; Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Show-Warn       { param([string]$Msg);  Write-Host ""; Write-Host "  [!!] $Msg" -ForegroundColor Yellow }
function Show-Fail       { param([string]$Msg);  Write-Host ""; Write-Host "  [XX] $Msg" -ForegroundColor Red }

function Enable-EnhancedPinPolicy {
    $regPath = "HKLM:\SOFTWARE\Policies\Microsoft\FVE"
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    # Enhanced PIN: harf/rakam/sembol kullanimina izin ver (Group Policy: Allow enhanced PINs for startup)
    Set-ItemProperty -Path $regPath -Name "UseEnhancedPin" -Value 1 -Type DWord -Force
    # Boot'ta PIN ister modu (UseTPMPIN): 1 = TPM + PIN gerekir
    Set-ItemProperty -Path $regPath -Name "UseTPM"       -Value 2 -Type DWord -Force
    Set-ItemProperty -Path $regPath -Name "UseTPMPIN"    -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $regPath -Name "UseTPMKey"    -Value 2 -Type DWord -Force
    Set-ItemProperty -Path $regPath -Name "UseTPMKeyPIN" -Value 2 -Type DWord -Force
    # Minimum PIN uzunlugu: 4 (Enhanced PIN icin)
    Set-ItemProperty -Path $regPath -Name "MinimumPIN"   -Value 4 -Type DWord -Force
}

function Test-TpmReady {
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        return ($tpm.TpmPresent -and $tpm.TpmReady -and $tpm.TpmEnabled)
    } catch {
        return $false
    }
}

function Encrypt-Drive {
    param(
        [string]$DriveLetter,
        [string]$ComputerName,
        [string]$SharedPassword,
        [bool]  $TpmReady
    )

    $mountPoint = $DriveLetter
    $isOSDrive  = ($mountPoint.ToUpper() -eq $env:SystemDrive.ToUpper())
    $useTpmPin  = ($isOSDrive -and $TpmReady)

    Write-Host ""
    Write-Host "  ================================================" -ForegroundColor DarkCyan
    if ($useTpmPin) {
        Write-Host "  Surucu: $mountPoint  [OS - TPM + PIN]" -ForegroundColor DarkCyan
    } elseif ($isOSDrive) {
        Write-Host "  Surucu: $mountPoint  [OS - Password (TPM yok)]" -ForegroundColor DarkCyan
    } else {
        Write-Host "  Surucu: $mountPoint  [Data - Password + AutoUnlock]" -ForegroundColor DarkCyan
    }
    Write-Host "  ================================================" -ForegroundColor DarkCyan

    $blStatus = Get-BitLockerVolume -MountPoint $mountPoint -ErrorAction SilentlyContinue
    if ($blStatus -and $blStatus.ProtectionStatus -eq "On") {
        Show-Warn "$mountPoint zaten sifreli. Cozulup yeniden sifreleniyor..."

        $blStatus.KeyProtector | ForEach-Object {
            Remove-BitLockerKeyProtector -MountPoint $mountPoint -KeyProtectorId $_.KeyProtectorId -ErrorAction SilentlyContinue | Out-Null
        }

        Disable-BitLocker -MountPoint $mountPoint | Out-Null

        Write-Host ""
        Write-Host "  Sifre cozme bekleniyor..." -ForegroundColor DarkYellow
        do {
            $vol = Get-BitLockerVolume -MountPoint $mountPoint
            $pct = if ($vol.EncryptionPercentage) { $vol.EncryptionPercentage } else { 0 }
            Show-ProgressBar -Percent (100 - $pct) -Status "Cozuluyor... (%$pct sifreli kaldi)"
            Start-Sleep -Seconds 5
        } while ($vol.VolumeStatus -eq "DecryptionInProgress" -or $vol.VolumeStatus -eq "FullyEncrypted")

        Write-Host ""
        Show-Done "$mountPoint tamamen cozuldu. Yeniden sifreleniyor..."
        Start-Sleep -Seconds 2
    }

    try {
        Show-StepHeader "$mountPoint -> Sifreleme baslatiliyor"

        for ($i = 0; $i -le 30; $i += 5) {
            Show-ProgressBar -Percent $i -Status "Hazirlaniyor..."
            Start-Sleep -Milliseconds 40
        }

        $secureSecret = ConvertTo-SecureString $SharedPassword -AsPlainText -Force

        if ($useTpmPin) {
            # OS surucu + TPM hazir: TPM + Enhanced PIN
            # Her boot'ta PIN sorulur, sifreleme anahtari TPM ile muhurlenir
            Enable-BitLocker -MountPoint $mountPoint `
                             -EncryptionMethod XtsAes256 `
                             -TpmAndPinProtector `
                             -Pin $secureSecret `
                             -SkipHardwareTest | Out-Null
        } else {
            # Data surucu veya TPM yoksa: Password protector
            Enable-BitLocker -MountPoint $mountPoint `
                             -EncryptionMethod XtsAes256 `
                             -PasswordProtector `
                             -Password $secureSecret `
                             -SkipHardwareTest | Out-Null
        }

        for ($i = 30; $i -le 70; $i += 5) {
            Show-ProgressBar -Percent $i -Status "Kurtarma anahtari ekleniyor..."
            Start-Sleep -Milliseconds 40
        }

        $recoveryResult = Add-BitLockerKeyProtector -MountPoint $mountPoint -RecoveryPasswordProtector
        $recoveryKey    = ($recoveryResult.KeyProtector |
                           Where-Object { $_.KeyProtectorType -eq "RecoveryPassword" } |
                           Select-Object -Last 1).RecoveryPassword

        if (-not $isOSDrive) {
            # Data surucu: OS acilinca otomatik kilit acsin
            for ($i = 70; $i -le 100; $i += 5) {
                Show-ProgressBar -Percent $i -Status "AutoUnlock etkinlestiriliyor..."
                Start-Sleep -Milliseconds 40
            }
            try {
                Enable-BitLockerAutoUnlock -MountPoint $mountPoint -ErrorAction SilentlyContinue | Out-Null
            } catch { }
        } else {
            for ($i = 70; $i -le 100; $i += 5) {
                Show-ProgressBar -Percent $i -Status "TPM muhru aktif..."
                Start-Sleep -Milliseconds 40
            }
        }

        Show-Done "$mountPoint sifreleme arkaplanda baslatildi."
        Write-Host "     Kurtarma : $recoveryKey" -ForegroundColor DarkYellow

        # ── ADIM 1: korubt Desktop'a recovery key yaz (API'den BAGIMSIZ) ──────
        Show-StepHeader "$mountPoint -> Kurtarma anahtari Desktop'a yaziliyor"
        Save-RecoveryKeyToDesktop -ComputerName $ComputerName `
                                   -DriveLetter  $mountPoint `
                                   -RecoveryKey  $recoveryKey `
                                   -Password     $SharedPassword | Out-Null

        # ── ADIM 2: API'ye kaydet ─────────────────────────────────────────────
        Show-StepHeader "$mountPoint -> Sunucuya kaydediliyor"

        for ($i = 0; $i -le 100; $i += 10) {
            Show-ProgressBar -Percent $i -Status "Kaydediliyor..."
            Start-Sleep -Milliseconds 30
        }

        $apiResult = Save-ToAPI -ComputerName $ComputerName `
                                -DriveLetter  $mountPoint `
                                -Password     $SharedPassword `
                                -RecoveryKey  $recoveryKey

        if ($apiResult) {
            Show-Done "$mountPoint veritabanina kaydedildi."
        } else {
            $logPath = "C:\Windows\Temp\bitlocker_backup.log"
            "$ComputerName | $mountPoint | $SharedPassword | $recoveryKey | $(Get-Date)" |
                Out-File -FilePath $logPath -Append -Encoding UTF8
            Show-Warn "$mountPoint API hatasi! Lokal yedege yazildi: $logPath"
        }
    }
    catch {
        Show-Fail "$mountPoint islenirken hata: $_"
    }
}

#endregion

#region Banner

Clear-Host
Write-Host ""
Write-Host "  +================================================+" -ForegroundColor Cyan
Write-Host "  |       BitLocker Otomatik Sifreleme             |" -ForegroundColor Cyan
Write-Host "  |       TPM + Enhanced PIN  /  HTTP + API Key    |" -ForegroundColor Cyan
Write-Host "  +================================================+" -ForegroundColor Cyan
Write-Host ""

#endregion

#region Yonetici Kontrolu

Show-StepHeader "Yonetici yetkisi kontrol ediliyor..."
Show-ProgressBar -Percent 0 -Status "Kontrol..."

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Show-Fail "Bu script yonetici olarak calistirilmalidir!"
    pause
    exit 1
}

Show-ProgressBar -Percent 100 -Status "Tamam" -Color Green
Show-Done "Yonetici yetkisi onaylandi."
Start-Sleep -Milliseconds 400

#endregion

#region Sifre API'den Cekiliyor

$computerName = $env:COMPUTERNAME

Show-StepHeader "Mevcut sifre API'den aliniyor: $computerName"

for ($i = 0; $i -le 60; $i += 10) {
    Show-ProgressBar -Percent $i -Status "Sorgulanıyor..."
    Start-Sleep -Milliseconds 40
}

$sharedPassword = Get-PasswordFromAPI -ComputerName $computerName

if (-not $sharedPassword) {
    Show-Fail "API'den sifre alinamadi! ComputerPasswords tablosunda '$computerName' kayitli mi?"
    Write-Host ""
    Write-Host "  Cozum: import_passwords.py ile bilgisayari veritabanina ekleyin." -ForegroundColor DarkYellow
    pause
    exit 1
}

Show-ProgressBar -Percent 100 -Status "Tamam" -Color Green
Show-Done "Sifre API'den alindi."
Start-Sleep -Milliseconds 300

#endregion

#region Diskleri Bul

Show-StepHeader "Diskler tespit ediliyor..."

for ($i = 0; $i -le 100; $i += 10) {
    Show-ProgressBar -Percent $i -Status "Taranıyor..."
    Start-Sleep -Milliseconds 30
}

# URETIM MODU: sadece sabit diskler (DriveType 3)
# TEST icin: { $_.DriveType -eq 3 -or $_.DriveType -eq 2 }
$allDrives = Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 }

Write-Host ""
foreach ($d in $allDrives) {
    Write-Host "  Bulundu: $($d.DeviceID)  [Sabit Disk]" -ForegroundColor DarkYellow
}

# OS surucusu daima ilk islensin (data surucu AutoUnlock'u OS BitLocker'a baglidir)
$osDrive = $env:SystemDrive.ToUpper()
$drives  = $allDrives | Select-Object -ExpandProperty DeviceID |
           Sort-Object @{ Expression = { if ($_.ToUpper() -eq $osDrive) { 0 } else { 1 } } }, @{ Expression = { $_ } }

Show-Done "$($drives.Count) adet disk bulundu."

#endregion

#region Enhanced PIN Policy + TPM Kontrolu

Show-StepHeader "Enhanced PIN policy uygulaniyor..."
for ($i = 0; $i -le 100; $i += 20) {
    Show-ProgressBar -Percent $i -Status "Registry policy yaziliyor..."
    Start-Sleep -Milliseconds 30
}
try {
    Enable-EnhancedPinPolicy
    Show-Done "Enhanced PIN policy aktif (alfanumerik PIN destegi)."
} catch {
    Show-Warn "Enhanced PIN policy yazilamadi: $_"
}

Show-StepHeader "TPM durumu kontrol ediliyor..."
for ($i = 0; $i -le 100; $i += 20) {
    Show-ProgressBar -Percent $i -Status "TPM sorgulaniyor..."
    Start-Sleep -Milliseconds 30
}
$tpmReady = Test-TpmReady
if ($tpmReady) {
    Show-Done "TPM hazir - OS surucu TPM + PIN ile sifrelenecek."
} else {
    Show-Warn "TPM hazir degil! OS surucu salt-Password modunda sifrelenecek."
}

Write-Host ""
Write-Host "  +-----------------------------------------------+" -ForegroundColor DarkCyan
Write-Host "  |  Bilgisayar  : $computerName" -ForegroundColor DarkCyan
Write-Host "  |  Diskler     : $($drives -join '  ')" -ForegroundColor DarkCyan
Write-Host "  |  OS surucu   : $osDrive  (ilk islenecek)" -ForegroundColor DarkCyan
Write-Host "  |  TPM hazir   : $tpmReady" -ForegroundColor DarkCyan
Write-Host "  |  PIN/Sifre   : [API'den alindi]" -ForegroundColor DarkCyan
Write-Host "  |  (Her disk ayri kurtarma anahtarina sahip)    |" -ForegroundColor DarkCyan
Write-Host "  +-----------------------------------------------+" -ForegroundColor DarkCyan

#endregion

#region Her Diski Sifrele

foreach ($drive in $drives) {
    Encrypt-Drive -DriveLetter    $drive `
                  -ComputerName   $computerName `
                  -SharedPassword $sharedPassword `
                  -TpmReady       $tpmReady
}

#endregion

#region Bitis

Write-Host ""
Write-Host "  +================================================+" -ForegroundColor Green
Write-Host "  |           TUM DISKLER ISLENDI [OK]             |" -ForegroundColor Green
Write-Host "  |   PIN/Sifre   : HTTP + API Key ile alindi     |" -ForegroundColor Green
Write-Host "  |   OS surucu   : TPM + Enhanced PIN             |" -ForegroundColor Green
Write-Host "  |   Data surucu : Password + AutoUnlock          |" -ForegroundColor Green
Write-Host "  |   Kurtarma    : korubt Desktop'a kaydedildi    |" -ForegroundColor Green
Write-Host "  |   Sifreleme arkaplanda devam ediyor            |" -ForegroundColor Green
Write-Host "  |   Boot oncesi PIN sorulacak (TPM muhru aktif)  |" -ForegroundColor Green
Write-Host "  +================================================+" -ForegroundColor Green
Write-Host ""

Write-Host "  Bu pencere 5 saniye sonra kapanacak..." -ForegroundColor DarkGray
Start-Sleep -Seconds 5

#endregion
