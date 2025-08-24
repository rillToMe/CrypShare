$ErrorActionPreference = "Stop"

$scriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$servePath   = "$scriptRoot\__TEMP__"
$uploadPath  = "$scriptRoot\uploads"
$cacheDir    = "$scriptRoot\cache"
$cacheFile   = "$cacheDir\pw_cache.txt"
$flagForget  = "$servePath\__FORGET_FLAG.txt"
$systemFolder= "$scriptRoot\System"
$logPath     = "$scriptRoot\Logs"
$port        = 8888

$pythonExe = Get-Command python -ErrorAction SilentlyContinue
if (-not $pythonExe) {
    Write-Host "❌ Python tidak ditemukan. Pastikan sudah terinstall dan masuk PATH." -ForegroundColor Red
    exit
}
$pythonExe = $pythonExe.Source

$requirementsFile = "$scriptRoot\requirements.txt"
if (-not (Test-Path $requirementsFile)) {
    Write-Host "⚠️ File requirements.txt tidak ditemukan. Buat file ini dengan isi:" -ForegroundColor Yellow
    Write-Host "watchdog" -ForegroundColor Yellow
    Write-Host "qrcode" -ForegroundColor Yellow
    Write-Host "cryptography" -ForegroundColor Yellow
    Write-Host "Lalu instal dengan: `pip install -r requirements.txt`" -ForegroundColor Yellow
} else {
    try {
        & $pythonExe -m pip install -r $requirementsFile -q
        # pastikan cryptography ada (dibutuhkan untuk fallback self-signed)
        & $pythonExe - << 'PY'
try:
    import cryptography  # noqa
except Exception:
    import sys, subprocess
    subprocess.check_call([sys.executable,"-m","pip","install","-q","cryptography"])
PY
        Write-Host "✅ Dependensi terinstal dari requirements.txt." -ForegroundColor Green
    } catch {
        Write-Host "❌ Gagal instal dependensi. Pastikan pip terinstall dan coba: `pip install -r requirements.txt`" -ForegroundColor Red
    }

$certDir  = Join-Path $scriptRoot "certs"
$ipCache  = Join-Path $cacheDir "ip_cache.txt"
$certFile = Join-Path $certDir "lan-cert.pem"
$keyFile  = Join-Path $certDir "lan-key.pem"
$scheme   = "https"  

function Get-PrimaryIPv4 {
    $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" |
             Sort-Object RouteMetric, InterfaceMetric |
             Select-Object -First 1
    if (-not $route) { return $null }
    $addr = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.IfIndex |
            Where-Object { $_.IPAddress -ne "127.0.0.1" } |
            Select-Object -First 1
    return $addr.IPAddress
}

$ip = Get-PrimaryIPv4
if (-not $ip) {
    Write-Host "❌ IP tidak ditemukan. Pastikan perangkat terhubung ke jaringan." -ForegroundColor Red
    exit
}

if (Test-Path $cacheFile) {
    $pw = (Get-Content $cacheFile -Raw).Trim()
    Write-Host "🔐 Password ditemukan di cache: $pw" -ForegroundColor Yellow
} else {
    $pw = Read-Host "🔐 Masukkan password akses"
    $pw = $pw.Trim()
    if ([string]::IsNullOrWhiteSpace($pw)) {
        Write-Host "❌ Password tidak boleh kosong." -ForegroundColor Red
        exit
    }
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    Set-Content $cacheFile $pw -Encoding UTF8
    Write-Host "✅ Password disimpan di: $cacheFile" -ForegroundColor Green
}

if (Test-Path $servePath) {
    try {
        Stop-Process -Name "python" -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Remove-Item -Recurse -Force $servePath -ErrorAction Stop
    } catch {
        Write-Host "⚠️ Gagal hapus folder, mencoba lagi..." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        try {
            Remove-Item -Recurse -Force $servePath -ErrorAction Stop
        } catch {
            Write-Host "❌ Gagal hapus folder __TEMP__. Tutup aplikasi lain yang mungkin mengunci folder." -ForegroundColor Red
            exit
        }
    }
}
New-Item -ItemType Directory -Path $servePath -Force | Out-Null

if (-not (Test-Path $uploadPath)) {
    New-Item -ItemType Directory -Path $uploadPath -Force | Out-Null
    Write-Host "📂 Folder uploads dibuat di: $uploadPath" -ForegroundColor Green
}
if (-not (Test-Path $logPath)) {
    New-Item -ItemType Directory -Path $logPath -Force | Out-Null
    Write-Host "📂 Folder logs dibuat di: $logPath" -ForegroundColor Green
}

$files = @("index.html", "files.html", "forget.html","help-https.html", "style.css", "script.js", "server.py", "logo.png")
foreach ($f in $files) {
    $sourceFile = "$systemFolder\$f"
    if (-not (Test-Path $sourceFile)) {
        Write-Host "❌ File $f tidak ditemukan di folder System." -ForegroundColor Red
        exit
    }
    Copy-Item $sourceFile "$servePath\$f" -Force
    Copy-Item $sourceFile "$logPath\$f" -Force
}


Write-Host "🔍 Mencoba update script.js di: $servePath\script.js" -ForegroundColor Cyan
$jsContent = Get-Content "$servePath\script.js" -Raw
$jsContent = [System.Text.RegularExpressions.Regex]::Replace($jsContent, '\{PASSWORD\}', [System.Text.RegularExpressions.Regex]::Escape($pw))
try {
    Set-Content "$servePath\script.js" $jsContent -Encoding UTF8 -ErrorAction Stop
    Write-Host "✅ script.js berhasil diupdate" -ForegroundColor Green
    $updatedJsContent = Get-Content "$servePath\script.js" -Raw
    if ($updatedJsContent -match "\{PASSWORD\}") {
        Write-Host "❌ {PASSWORD} masih ada di script.js, gagal replace!" -ForegroundColor Red
    } else {
        Write-Host "✅ {PASSWORD} berhasil diganti jadi $pw di script.js" -ForegroundColor Green
    }
} catch {
    Write-Host "❌ Gagal update script.js: $_" -ForegroundColor Red
    exit
}

function Update-FileList {
    $body = "<ul>"
    Get-ChildItem -Path $uploadPath | ForEach-Object {
        if ($_.PSIsContainer) {
            $body += "<li><a href='/download_folder/$($_.Name)' download>$($_.Name).zip</a> (Folder)</li>"
        } else {
            $ext = $_.Extension.ToLower()
            $fileUrl = "/uploads/$($_.Name)"
            if ($ext -in @(".png", ".jpg", ".jpeg", ".gif")) {
                $body += "<li><img src='$fileUrl' class='preview' alt='$($_.Name)'><br><a href='$fileUrl' download>$($_.Name)</a> (Gambar)</li>"
            } elseif ($ext -in @(".mp4", ".webm", ".ogg")) {
                $videoType = "video/" + $ext.Replace(".", "")
                $body += "<li><video controls class='video-preview'><source src='$fileUrl' type='$videoType'>Browser kamu gak support video ini.</video><br><a href='$fileUrl' download>$($_.Name)</a> (Video)</li>"
            } else {
                $body += "<li><a href='$fileUrl' download>$($_.Name)</a></li>"
            }
        }
    }
    $body += "</ul>"
    $htmlFileList = Get-Content "$servePath\files.html" -Raw
    $htmlFileList = $htmlFileList -replace "\{FILELIST\}", $body
    Set-Content "$servePath\files.html" $htmlFileList -Encoding UTF8
}
Update-FileList

if (!(Test-Path $certDir)) { New-Item -ItemType Directory -Path $certDir -Force | Out-Null }
if (!(Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }

$needRegen = $true
if ((Test-Path $ipCache) -and (Test-Path $certFile) -and (Test-Path $keyFile)) {
    $lastIp = (Get-Content $ipCache -Raw).Trim()
    if ($lastIp -eq $ip) { $needRegen = $false }
}

if ($needRegen) {
  Write-Host "🔑 Membuat/refresh sertifikat HTTPS untuk IP $ip ..." -ForegroundColor Cyan
  $mkcert = Get-Command mkcert -ErrorAction SilentlyContinue
  $useFallback = $false

  if ($mkcert) {
    & $mkcert.Source -key-file $keyFile -cert-file $certFile `
      "digitalin.local" "localhost" "127.0.0.1" "::1" "$ip"
    if ($LASTEXITCODE -ne 0) { $useFallback = $true }
  } else {
    $useFallback = $true
  }

  if ($useFallback) {
    Write-Host "ℹ️ mkcert tidak tersedia → pakai self-signed fallback (browser akan warning)." -ForegroundColor Yellow
    $genPy = @"
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from datetime import datetime, timedelta
import ipaddress, os

ip = "$ip"
names = ["digitalin.local","localhost","127.0.0.1","::1", ip]

key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
subject = issuer = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, u"Local Dev Self-Signed")])
alt_names = []
for n in names:
    try: alt_names.append(x509.IPAddress(ipaddress.ip_address(n)))
    except ValueError: alt_names.append(x509.DNSName(n))

cert = (x509.CertificateBuilder()
    .subject_name(subject)
    .issuer_name(issuer)
    .public_key(key.public_key())
    .serial_number(x509.random_serial_number())
    .not_valid_before(datetime.utcnow() - timedelta(minutes=1))
    .not_valid_after(datetime.utcnow() + timedelta(days=3650))
    .add_extension(x509.SubjectAlternativeName(alt_names), critical=False)
    .sign(key, hashes.SHA256()))

os.makedirs(r"$certDir", exist_ok=True)
with open(r"$keyFile","wb") as f:
    f.write(key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.TraditionalOpenSSL,
        encryption_algorithm=serialization.NoEncryption()))
with open(r"$certFile","wb") as f:
    f.write(cert.public_bytes(serialization.Encoding.PEM))

with open(r"$certDir\lan-cert.cer","wb") as f:
    f.write(cert.public_bytes(serialization.Encoding.DER))
"@
    $tmpPy = Join-Path $env:TEMP "gen_selfsigned_https.py"
    Set-Content $tmpPy $genPy -Encoding UTF8
    & $pythonExe $tmpPy
    Remove-Item $tmpPy -Force -ErrorAction SilentlyContinue
  }

  Set-Content $ipCache $ip -Encoding UTF8
}

if ((Test-Path $certFile) -and (Test-Path $keyFile)) {
    $env:HTTPS_CERT = $certFile
    $env:HTTPS_KEY  = $keyFile
} else {
    Remove-Item Env:\HTTPS_CERT -ErrorAction SilentlyContinue
    Remove-Item Env:\HTTPS_KEY  -ErrorAction SilentlyContinue
    $scheme = "http"
}

$url = "{0}://{1}:{2}" -f $scheme, $ip, $port
$qrTemp = "$env:TEMP\qr_temp.py"
$qrScript = @"
import qrcode
url = "$url"
img = qrcode.make(url)
print("🔗 Link:", url)
img.show()
"@
Set-Content -Path $qrTemp -Value $qrScript -Encoding UTF8
Start-Process $pythonExe -ArgumentList "`"$qrTemp`"" -NoNewWindow

$serverJob = Start-Job -ScriptBlock {
    param($servePath, $pythonExe)
    Set-Location -Path $servePath
    & $pythonExe server.py
} -ArgumentList $servePath, $pythonExe

Start-Sleep -Seconds 2
if ($serverJob.State -eq "Failed") {
    Write-Host "❌ Gagal menjalankan server. Error: $($serverJob.ChildJobs[0].Error)" -ForegroundColor Red
    Stop-Job -Job $serverJob
    Remove-Job -Job $serverJob
    exit
}

Write-Host ("`n🚀 Server berjalan di: {0}://{1}:{2}" -f $scheme, $ip, $port) -ForegroundColor Green
Write-Host ("🔗 Akses lokal juga: {0}://127.0.0.1:{1}" -f $scheme, $port) -ForegroundColor Green
Write-Host "📂 Taruh file untuk di-download di: $uploadPath" -ForegroundColor Green
Write-Host "📝 Jalankan manual: cd $logPath; python server.py untuk debug" -ForegroundColor Green
Write-Host "ℹ️ Instal dependensi: `pip install -r requirements.txt` jika belum" -ForegroundColor Green

$watchJob = Start-Job -ScriptBlock {
    param($uploadPath, $servePath)
    function Update-FileList {
        $body = "<ul>"
        Get-ChildItem -Path $uploadPath | ForEach-Object {
            if ($_.PSIsContainer) {
                $body += "<li><a href='/download_folder/$($_.Name)' download>$($_.Name).zip</a> (Folder)</li>"
            } else {
                $ext = $_.Extension.ToLower()
                $fileUrl = "/uploads/$($_.Name)"
                if ($ext -in @(".png", ".jpg", ".jpeg", ".gif")) {
                    $body += "<li><img src='$fileUrl' class='preview' alt='$($_.Name)'><br><a href='$fileUrl' download>$($_.Name)</a> (Gambar)</li>"
                } elseif ($ext -in @(".mp4", ".webm", ".ogg")) {
                    $videoType = "video/" + $ext.Replace(".", "")
                    $body += "<li><video controls class='video-preview'><source src='$fileUrl' type='$videoType'>Browser kamu gak support video ini.</video><br><a href='$fileUrl' download>$($_.Name)</a> (Video)</li>"
                } else {
                    $body += "<li><a href='$fileUrl' download>$($_.Name)</a></li>"
                }
            }
        }
        $body += "</ul>"
        $htmlFileList = Get-Content "$servePath\files.html" -Raw
        $htmlFileList = $htmlFileList -replace "\{FILELIST\}", $body
        Set-Content "$servePath\files.html" $htmlFileList -Encoding UTF8
    }

    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $uploadPath
    $watcher.IncludeSubdirectories = $true
    $watcher.EnableRaisingEvents = $true
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor [System.IO.NotifyFilters]::DirectoryName

    Register-ObjectEvent $watcher "Created" -Action {
        Update-FileList
        Write-Host "🔄 Daftar file diperbarui! (created)" -ForegroundColor Cyan
    } | Out-Null
    Register-ObjectEvent $watcher "Deleted" -Action {
        Update-FileList
        Write-Host "🔄 Daftar file diperbarui! (deleted)" -ForegroundColor Cyan
    } | Out-Null
    Register-ObjectEvent $watcher "Renamed" -Action {
        Update-FileList
        Write-Host "🔄 Daftar file diperbarui! (renamed)" -ForegroundColor Cyan
    } | Out-Null

    while ($true) { Start-Sleep -Seconds 1 }
} -ArgumentList $uploadPath, $servePath

Start-Job -ScriptBlock {
    param($flagPath, $cacheFile)
    while ($true) {
        Start-Sleep -Seconds 2
        if (Test-Path $flagPath) {
            Remove-Item $flagPath -Force -ErrorAction SilentlyContinue
            Remove-Item $cacheFile -Force -ErrorAction SilentlyContinue
            Write-Host "`n🔁 Password di-reset. Silakan restart skrip." -ForegroundColor Cyan
            break
        }
    }
} -ArgumentList $flagForget, $cacheFile | Out-Null

do {
    $choice = Read-Host "`nTekan [ENTER] untuk hentikan server, atau ketik 'help' untuk lihat menu:"
    if ($choice -eq "help") {
        Write-Host "=== Menu ===" -ForegroundColor Cyan
        Write-Host "1. debug save      - Simpan folder __TEMP__ untuk debug" -ForegroundColor Cyan
        Write-Host "2. restart server  - Restart server tanpa hentikan skrip" -ForegroundColor Cyan
        Write-Host "3. clear cache     - Hapus file cache password" -ForegroundColor Cyan
        Write-Host "4. regen cert      - Regenerasi sertifikat HTTPS untuk IP aktif" -ForegroundColor Cyan
        Write-Host "Ketik nomor pilihan atau 'help' lagi untuk ulang, [ENTER] untuk keluar" -ForegroundColor Cyan
        $menuChoice = Read-Host "Pilih opsi (1-4):"
        switch ($menuChoice) {
            "1" {
                Write-Host "✅ Folder __TEMP__ disimpan untuk debug di: $servePath" -ForegroundColor Green
            }
            "2" {
                Stop-Job -Job $serverJob -ErrorAction SilentlyContinue
                Remove-Job -Job $serverJob -ErrorAction SilentlyContinue
                Stop-Process -Name "python" -ErrorAction SilentlyContinue
                $serverJob = Start-Job -ScriptBlock {
                    param($servePath, $pythonExe)
                    Set-Location -Path $servePath
                    & $pythonExe server.py
                } -ArgumentList $servePath, $pythonExe
                Start-Sleep -Seconds 2
                if ($serverJob.State -eq "Running") {
                    Write-Host "✅ Server berhasil di-restart" -ForegroundColor Green
                } else {
                    Write-Host "❌ Gagal restart server" -ForegroundColor Red
                }
            }
            "3" {
                if (Test-Path $cacheFile) {
                    Remove-Item $cacheFile -Force -ErrorAction SilentlyContinue
                    Write-Host "✅ Cache password dihapus dari: $cacheFile" -ForegroundColor Green
                } else {
                    Write-Host "⚠️ Cache tidak ditemukan" -ForegroundColor Yellow
                }
                $pw = Read-Host "🔐 Masukkan password akses baru"
                $pw = $pw.Trim()
                if ([string]::IsNullOrWhiteSpace($pw)) {
                    Write-Host "❌ Password tidak boleh kosong." -ForegroundColor Red
                } else {
                    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
                    Set-Content $cacheFile $pw -Encoding UTF8
                    Write-Host "✅ Password baru disimpan di: $cacheFile" -ForegroundColor Green
                    if (Test-Path $servePath) {
                        $jsContent = Get-Content "$servePath\script.js" -Raw -ErrorAction SilentlyContinue
                        if ($jsContent) {
                            $jsContent = [System.Text.RegularExpressions.Regex]::Replace($jsContent, '\{PASSWORD\}', [System.Text.RegularExpressions.Regex]::Escape($pw))
                            Set-Content "$servePath\script.js" $jsContent -Encoding UTF8
                            Write-Host "✅ Password di-update di script.js" -ForegroundColor Green
                        } else {
                            Write-Host "⚠️ Gagal baca script.js, cek folder __TEMP__" -ForegroundColor Yellow
                        }
                    } else {
                        Write-Host "⚠️ Folder __TEMP__ tidak ditemukan, coba restart skrip" -ForegroundColor Yellow
                    }
                }
            }
            "4" {
                $mkcert = Get-Command mkcert -ErrorAction SilentlyContinue
                if (-not $mkcert) {
                    Write-Host "❌ mkcert belum terpasang. Install dulu lalu jalankan ulang: mkcert -install" -ForegroundColor Red
                } else {
                    if (!(Test-Path $certDir)) { New-Item -ItemType Directory -Path $certDir -Force | Out-Null }
                    & $mkcert.Source -key-file $keyFile -cert-file $certFile `
                        "digitalin.local" "localhost" "127.0.0.1" "::1" "$ip"
                    if ($LASTEXITCODE -ne 0) {
                        Write-Host "❌ Gagal regen sertifikat." -ForegroundColor Red
                    } else {
                        Set-Content $ipCache $ip -Encoding UTF8
                        $env:HTTPS_CERT = $certFile
                        $env:HTTPS_KEY  = $keyFile
                        Write-Host "✅ Sertifikat diregenerasi untuk IP $ip" -ForegroundColor Green
                    }
                }
            }
            default {
                Write-Host "⚠️ Pilihan tidak valid, coba lagi" -ForegroundColor Yellow
            }
        }
    }
} while ($choice -eq "help")

if ($choice -ne "help") {
    Stop-Job -Job $serverJob -ErrorAction SilentlyContinue
    Remove-Job -Job $serverJob -ErrorAction SilentlyContinue
    Stop-Job -Job $watchJob -ErrorAction SilentlyContinue
    Remove-Job -Job $watchJob -ErrorAction SilentlyContinue
    Stop-Process -Name "python" -ErrorAction SilentlyContinue
    Remove-Item $servePath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $qrTemp -Force -ErrorAction SilentlyContinue
    Write-Host "`n✅ Server dimatikan & folder __TEMP__ dibersihkan." -ForegroundColor Green
    Write-Host "📂 Folder uploads ($uploadPath) tetap aman." -ForegroundColor Green
}
