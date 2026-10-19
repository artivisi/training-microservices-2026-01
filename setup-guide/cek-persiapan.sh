#!/usr/bin/env bash
# Pemeriksaan kesiapan laptop peserta — Training Arsitektur Microservices dan Cloud dengan Golang.
# Jalankan di macOS (Terminal) atau di Ubuntu WSL2 / Linux:
#   curl -fsSL https://raw.githubusercontent.com/artivisi/training-microservices-2026-01/main/setup-guide/cek-persiapan.sh | bash
# Hasil tersimpan di ~/cek-persiapan.log; kirim file tersebut ke PIC.
set -u

LOG="$HOME/cek-persiapan.log"
GIT_HOST=git.training.artivisi.id
K3S_IMAGE=rancher/k3s:v1.36.5-k3s1
IMAGES=(
  postgres:18.6-alpine
  apache/kafka:4.3.1
  oryd/hydra:v26.2.0
  grafana/otel-lgtm:0.37.0
  golang:1.27.2-alpine
  "$K3S_IMAGE"
  ghcr.io/k3d-io/k3d-proxy:5.9.0
  ghcr.io/k3d-io/k3d-tools:5.9.0
)

GAGAL=0
ok()    { printf '[OK]    %s\n' "$1"; }
gagal() { printf '[GAGAL] %s\n' "$1"; GAGAL=$((GAGAL + 1)); }
judul() { printf '\n== %s\n' "$1"; }

# versi_min <terpasang> <minimum>: benar bila terpasang >= minimum
versi_min() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

periksa_versi() { # nama perintah-versi regex minimum
  local nama=$1 cmd=$2 re=$3 min=$4 out v
  if ! out=$(eval "$cmd" 2>&1); then gagal "$nama tidak ditemukan atau gagal dijalankan"; return; fi
  v=$(printf '%s' "$out" | grep -oE "$re" | head -n1)
  if [ -z "$v" ]; then gagal "$nama: versi tidak terbaca dari keluaran '$out'"; return; fi
  if versi_min "$v" "$min"; then ok "$nama $v"; else gagal "$nama $v, minimal $min"; fi
}

periksa_url() { # label url kode-http-yang-diterima(regex)
  local code
  code=$(curl -sS -o /dev/null -m 15 -w '%{http_code}' "$2" 2>/dev/null)
  if [[ $code =~ ^($3)$ ]]; then ok "$1 ($2 → HTTP $code)"; else gagal "$1 tidak terjangkau ($2 → HTTP ${code:-000})"; fi
}

{
  echo "Pemeriksaan kesiapan laptop — $(date '+%Y-%m-%d %H:%M')"
  echo "Sistem: $(uname -srm)"
  grep -qi microsoft /proc/version 2>/dev/null && echo "Berjalan di WSL2"

  judul "Perangkat lunak"
  periksa_versi "Go"                 "go version"                  '[0-9]+\.[0-9]+(\.[0-9]+)?' 1.26
  periksa_versi "protoc"             "protoc --version"            '[0-9]+\.[0-9]+(\.[0-9]+)?' 33.0
  periksa_versi "protoc-gen-go"      "protoc-gen-go --version"     '[0-9]+\.[0-9]+\.[0-9]+'    1.36.0
  periksa_versi "protoc-gen-go-grpc" "protoc-gen-go-grpc --version" '[0-9]+\.[0-9]+\.[0-9]+'   1.5.0
  periksa_versi "Git"                "git --version"               '[0-9]+\.[0-9]+(\.[0-9]+)?' 2.30
  periksa_versi "Make"               "make --version"              '[0-9]+\.[0-9]+'            3.81
  if dv=$(docker version --format '{{.Server.Version}}' 2>&1) && [[ $dv =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    if versi_min "$dv" 25.0.0; then ok "Docker Engine $dv"; else gagal "Docker Engine $dv, minimal 25.0.0"; fi
  else
    gagal "Docker Engine tidak dikenali (server: $(docker version --format '{{.Server.Platform.Name}} {{.Server.Version}}' 2>&1)); gunakan Docker Desktop atau Docker Engine"
  fi
  periksa_versi "Docker Compose"     "docker compose version --short" '[0-9]+\.[0-9]+\.[0-9]+'  2.20.0
  periksa_versi "k3d"                "k3d version"                 '[0-9]+\.[0-9]+\.[0-9]+'    5.8.0
  periksa_versi "kubectl"            "kubectl version --client"    '[0-9]+\.[0-9]+\.[0-9]+'    1.35.0

  judul "Kapasitas"
  mem=$(docker info --format '{{.MemTotal}}' 2>/dev/null)
  if [ -n "$mem" ] && [ "$mem" -ge $((8 * 1024 * 1024 * 1024 - 512 * 1024 * 1024)) ]; then
    ok "Memori untuk Docker $(awk -v m="$mem" 'BEGIN {printf "%.1f", m / 1073741824}') GB"
  else
    gagal "Memori untuk Docker $(awk -v m="${mem:-0}" 'BEGIN {printf "%.1f", m / 1073741824}') GB, minimal 8 GB"
  fi
  free_kb=$(df -Pk "$HOME" | awk 'NR==2 {print $4}')
  if [ "$free_kb" -ge $((25 * 1024 * 1024)) ]; then ok "Ruang disk kosong $((free_kb / 1024 / 1024)) GB"
  else gagal "Ruang disk kosong $((free_kb / 1024 / 1024)) GB, minimal 25 GB"; fi

  judul "Akses jaringan"
  periksa_url "Go module proxy"   https://proxy.golang.org/google.golang.org/grpc/@latest '200'
  periksa_url "Go checksum DB"    https://sum.golang.org/latest '200'
  periksa_url "Docker Hub"        https://registry-1.docker.io/v2/ '401'
  periksa_url "GitHub Container Registry" https://ghcr.io/v2/ '401|405'
  periksa_url "GitHub"            https://github.com '200'
  periksa_url "Git server training (HTTPS)" "https://$GIT_HOST/user/login" '200'
  periksa_url "Container registry training" "https://$GIT_HOST/v2/" '401'
  ssh_out=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    -o PreferredAuthentications=publickey -T "git@$GIT_HOST" 2>&1)
  if printf '%s' "$ssh_out" | grep -qiE 'permission denied|successfully authenticated|Hi there'; then
    ok "Git server training (SSH port 22)"
  else
    gagal "Git server training (SSH port 22) tidak terjangkau: $ssh_out"
  fi

  judul "Download image Docker (beberapa menit pada pemeriksaan pertama)"
  for img in "${IMAGES[@]}"; do
    if docker pull -q "$img" >/dev/null 2>&1; then ok "$img"; else gagal "docker pull $img"; fi
  done

  judul "Docker Compose"
  tmp=$(mktemp -d)
  cat > "$tmp/compose.yaml" <<'EOF'
services:
  db:
    image: postgres:18.6-alpine
    environment:
      POSTGRES_PASSWORD: cek
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 2s
      retries: 30
EOF
  if docker compose -f "$tmp/compose.yaml" -p cek-persiapan up -d --wait >/dev/null 2>&1; then
    ok "docker compose up (PostgreSQL sehat)"
  else
    gagal "docker compose up"
  fi
  docker compose -f "$tmp/compose.yaml" -p cek-persiapan down -v >/dev/null 2>&1
  rm -rf "$tmp"

  judul "Cluster Kubernetes lokal (k3d)"
  k3d cluster delete cek-persiapan >/dev/null 2>&1
  if k3d cluster create cek-persiapan --image "$K3S_IMAGE" --wait --timeout 180s >/dev/null 2>&1 \
     && kubectl --context k3d-cek-persiapan wait --for=condition=Ready node --all --timeout=120s >/dev/null 2>&1; then
    ok "k3d cluster create, node Ready"
  else
    gagal "k3d cluster create"
  fi
  k3d cluster delete cek-persiapan >/dev/null 2>&1

  echo
  if [ "$GAGAL" -eq 0 ]; then echo "HASIL: SEMUA PEMERIKSAAN LULUS"; else echo "HASIL: $GAGAL PEMERIKSAAN GAGAL"; fi
} 2>&1 | tee "$LOG"

echo
echo "Log tersimpan di $LOG"
