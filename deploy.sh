#!/bin/bash
set -e
echo "=== Swaranjaliya Deploy Script ==="
echo "Target: /opt/swaranjaliya | swaranjaliya.com"

# 1. Download zip
echo "[1/9] Downloading source..."
cd /tmp
wget -q -O swaranjaliya.zip "https://sinhala-audio.preview.emergentagent.com/api/dl/swaranjaliya-6831c12b"
CHECKSUM=$(md5sum swaranjaliya.zip | cut -d' ' -f1)
if [ "$CHECKSUM" != "839fcd0899b6a706c3c4f305051e0cc2" ]; then
  echo "ERROR: MD5 mismatch ($CHECKSUM). Abort." && exit 1
fi
echo "   Checksum OK"

# 2. Extract
echo "[2/9] Extracting to /opt/swaranjaliya..."
rm -rf /opt/swaranjaliya
mkdir -p /opt/swaranjaliya
unzip -q swaranjaliya.zip -d /opt/swaranjaliya

# 3. Patch .env for production
echo "[3/9] Patching .env for production..."
cd /opt/swaranjaliya
sed -i 's|DB_NAME="test_database"|DB_NAME="swaranjaliya"|g' backend/.env
sed -i 's|CORS_ORIGINS="[^"]*"|CORS_ORIGINS="https://swaranjaliya.com"|g' backend/.env
# Frontend
echo "REACT_APP_BACKEND_URL=https://swaranjaliya.com" > frontend/.env

# 4. System packages
echo "[4/9] Installing system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3-pip python3-venu nodejs npm mongodb 2>/dev/null || true
npm install -g yarn 2>/dev/null || true
# Start MongoDB
systemctl start mongod 2>/dev/null || mongod --fork --logpath /var/log/mongod.log --dbpath /var/lib/mongodb 2>/dev/null || true

# 5. Python backend
echo "[5/9] Installing Python dependencies..."
cd /opt/swaranjaliya/backend
python3 -m venv venv
source venv/bin/activate
pip install -q -r requirements.txt
pip install -q emergentintegrations --extra-index-url https://d33sy5i8bnduwe.cloudfront.net/simple/
deactivate

# 6. Frontend build
echo "[6/9] Building React frontend..."
cd /opt/swaranjaliya/frontend
yarn install --silent 2>&1 | tail -3
yarn build 2>&1 | tail -5

# 7. Systemd service
echo "[7/9] Creating systemd service..."
cat > /etc/systemd/system/swaranjaliya-api.service << 'UNIT'
[Unit]
Description=Swaranjaliya API
After=network.target mongod.service
[Service]
WorkingDirectory=/opt/swaranjaliya/backend
EnvironmentFile=/opt/swaranjaliya/backend/.env
ExecStart=/opt/swaranjaliya/backend/venv/bin/uvicorn server:app --host 127.0.0.1 --port 8001
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable swaranjaliya-api
systemctl restart swaranjaliya-api

# 8. Nginx config
echo "[8/9] Configuring Nginx..."
cat > /etc/nginx/sites-available/swaranjaliya << 'NGINX'
server {
    listen 80;
    server_name swaranjaliya.com www.swaranjaliya.com;
    root /opt/swaranjaliya/frontend/build;
    index index.html;
    client_max_body_size 200M;
    location /api/ {
        proxy_pass http://127.0.0.1:8001;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
    }
    location / {
        try_files $uri $uri/ /index.html;
    }
}
NGINX
ln -sf /etc/nginx/sites-available/swaranjaliya /etc/nginx/sites-enabled/swaranjaliya
nginx -t && systemctl reload nginx

# 9. Smoke test
echo "[9/9] Smoke test..."
sleep 3
HEALTH=$(curl -s http://127.0.0.1:8001/ | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('message','?'))" 2>/dev/null || echo "starting...")
echo "API: $HEALTH"
echo ""
echo "=== DONE ==="
echo "Visit: https://swaranjaliya.com"
echo "Admin: https://swaranjaliya.com/rooms/sindu-kamare/admin"
