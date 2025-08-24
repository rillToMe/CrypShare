import os
import socket
import qrcode

ip = socket.gethostbyname(socket.gethostname())
port = int(os.getenv("PORT", "8888"))

if os.getenv("HTTPS_CERT") and os.getenv("HTTPS_KEY"):
    scheme = "https"
else:
    scheme = "http"

url = f"{scheme}://{ip}:{port}"

img = qrcode.make(url)
print("🔗 Link:", url)
img.show()
