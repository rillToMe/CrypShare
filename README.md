# 🔒 CrypShare

CrypShare is a lightweight solution for sharing files across local networks with a modern HTTPS-enabled interface.  
Featuring a sleek **dark neon UI**, CrypShare provides a secure, fast, and elegant experience across devices.

---

## ✨ Features

- 📂 Upload & Download files directly via browser  
- 🔒 Password-protected access  
- 🌐 HTTPS support (self-signed / mkcert)  
- 📱 QR Code for quick mobile access  
- 🖼 Dark neon UI with photo & video preview  
- ⚡ Real-time auto refresh (watchdog + SSE)  

---

## 📦 Installation

### 1. Clone the repository
```bash
git clone https://github.com/rillToMe/CrypShare.git
cd CrypShare
```

### 2. Install Python dependencies
```bash
pip install -r requirements.txt
```

> Requirements:  
> - Python 3.8+  
> - watchdog, qrcode, cryptography

### 3. (Optional) Install [mkcert](https://github.com/FiloSottile/mkcert) for trusted HTTPS certificates
```bash
mkcert -install
```

---

## ▶️ Running

On Windows (PowerShell):
```powershell
.\TransferPy.ps1
```

Access the server via:
- **Local** → `https://127.0.0.1:8888/files.html`  
- **LAN** → `https://<LAN-IP>:8888/files.html`  

---

## 📜 Project Structure

```
CrypShare/
├─ System/           # UI (html, css, js, server.py)
├─ uploads/          # file storage
├─ Logs/             # logs & debug files
├─ cache/            # cached password/ip
├─ certs/            # https certificates
├─ TransferPy.ps1    # PowerShell launcher
├─ requirements.txt  # python dependencies
└─ README.md
```

---

## 🏗 Architecture

![Architecture Diagram](assets/architecture_diagram.png)

---

## 📄 License

Apache 2.0 License

---

## 👤 Author

Created by **Rahmat Aditya** (`@rillToMe`)  
Part of the **Aether Studio** ecosystem 🚀
