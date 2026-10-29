#!/usr/bin/env bash
# Lab 10 on your own server: one Ubuntu 24.04 VPS (x86_64, 4 vCPU, 8 GB RAM)
# that runs everything the training server and the git server provide.
#
#   Caddy (80, 443)  TLS for git.<domain>, auth.<domain>, app.<domain>
#   Forgejo          git over HTTPS, container registry, Actions (git.<domain>)
#   forgejo-runner   label "host", jobs run on this machine as user runner
#   k3s              single node; Traefik on 8080 behind Caddy
#     namespace infra    PostgreSQL, Kafka, Hydra (auth.<domain>), otel-lgtm
#     namespace <NAME>   Secrets the server overlay expects, kubeconfig for the pipeline
#
# Before running: three DNS A records, git.<domain>, auth.<domain> and
# app.<domain>, pointing to this server, and ports 80 and 443 reachable from
# the internet (Let's Encrypt HTTP-01).
#
# Run as root from a clone of the repository:
#   DOMAIN=lab.example.com FORGE_USER=budi FORGE_EMAIL=budi@example.com \
#     ./studi-kasus/server/setup.sh
# FORGE_USER is the git server account and also the name of the namespace,
# the database prefix, the Kafka topic prefix and the OAuth2 client prefix.
#
# Safe to run again: what exists is kept, generated passwords stay in
# /opt/lab10/secrets. The values for the lab end up in /root/lab10.txt.
set -euo pipefail

# Pinned versions: k3s as the rancher/k3s image of Lab 9, kubectl the same
# minor, images as in studi-kasus/compose.yaml.
K3S_VERSION=v1.36.5+k3s1
KUBECTL_VERSION=v1.36.5
GO_VERSION=1.27.2
FORGEJO_RUNNER_VERSION=13.2.0
export POSTGRES_IMAGE=postgres:18.6-alpine
export KAFKA_IMAGE=apache/kafka:4.3.1
export HYDRA_IMAGE=oryd/hydra:v26.2.0
export OTEL_LGTM_IMAGE=grafana/otel-lgtm:0.37.0

HERE=$(cd "$(dirname "$0")" && pwd)
STATE=/opt/lab10
SECRETS=$STATE/secrets
ADMIN_KUBECONFIG=/etc/rancher/k3s/k3s.yaml
KUBECTL="/usr/local/bin/kubectl --kubeconfig $ADMIN_KUBECONFIG"
SERVICES=(account transfer notification)

die() { echo "setup.sh: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

# --- Checks -------------------------------------------------------------------

[[ $(id -u) == 0 ]] || die "run as root"
missing=()
for v in DOMAIN FORGE_USER FORGE_EMAIL; do [[ -n ${!v:-} ]] || missing+=("$v"); done
(( ${#missing[@]} == 0 )) || die "missing required variables: ${missing[*]}"
. /etc/os-release
[[ $ID == ubuntu ]] || die "Ubuntu required, this is $PRETTY_NAME"
[[ $(uname -m) == x86_64 ]] || die "x86_64 required, this is $(uname -m)"
# The user name is also a namespace, a Kafka topic prefix and an image path:
# lowercase letters, digits and dashes only.
[[ $FORGE_USER =~ ^[a-z][a-z0-9-]{1,30}[a-z0-9]$ ]] ||
  die "FORGE_USER must be lowercase letters, digits and dashes (3-32 characters), got '$FORGE_USER'"
[[ $FORGE_USER != admin ]] || die "FORGE_USER 'admin' is reserved by the git server"
for h in git auth app; do
  getent ahostsv4 "$h.$DOMAIN" >/dev/null || die "$h.$DOMAIN does not resolve: create the DNS A record first"
done
# The address of this node in the cluster network; Caddy forwards to Traefik there.
NODE_IP=$(ip -4 route get 1.1.1.1 | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
[[ -n $NODE_IP ]] || die "cannot find this server's IPv4 address (ip route get 1.1.1.1)"
export DOMAIN NODE_IP
export NAME=$FORGE_USER

mkdir -p "$SECRETS" && chmod 700 "$STATE" "$SECRETS"

# Generated once, read on every run.
secret() {
  local f=$SECRETS/$1
  [[ -s $f ]] || (umask 077; openssl rand -hex "$2" > "$f")
  cat "$f"
}

# fetch <url> <dest> <sha256>
fetch() {
  local tmp
  tmp=$(mktemp)
  curl -fsSL -o "$tmp" "$1"
  echo "$3  $tmp" | sha256sum -c --quiet - || { rm -f "$tmp"; die "checksum mismatch for $1"; }
  install -m 0755 "$tmp" "$2"
  rm -f "$tmp"
}
sha_of() { curl -fsSL "$1" | awk '{print $1; exit}'; }

render() { envsubst "$(printf '${%s} ' "${@:2}")" < "$1"; }

# --- Packages -----------------------------------------------------------------

step "Packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q docker.io docker-compose-v2 docker-buildx make git jq curl gettext-base openssl

# --- Git server: Forgejo + Caddy -------------------------------------------

step "Git server (Forgejo, Caddy)"
mkdir -p "$STATE/forge"
cmp -s "$HERE/Caddyfile" "$STATE/forge/Caddyfile" && caddy_changed=false || caddy_changed=true
install -m 0644 "$HERE/compose.yaml" "$HERE/Caddyfile" "$STATE/forge/"
(umask 077; printf 'DOMAIN=%s\nNODE_IP=%s\nFORGE_SECRET_KEY=%s\nFORGE_INTERNAL_TOKEN=%s\n' \
  "$DOMAIN" "$NODE_IP" "$(secret forge-secret-key 32)" "$(secret forge-internal-token 48)" > "$STATE/forge/.env")
compose=(docker compose --project-directory "$STATE/forge" -f "$STATE/forge/compose.yaml")
"${compose[@]}" up -d
# A changed Caddyfile on a running container: up -d does not notice it.
$caddy_changed && "${compose[@]}" restart caddy
forgejo() { "${compose[@]}" exec -T -u git forgejo forgejo "$@"; }

for i in $(seq 60); do forgejo admin user list >/dev/null 2>&1 && break; sleep 2; done
forgejo admin user list >/dev/null || die "Forgejo did not start: docker compose -f $STATE/forge/compose.yaml logs forgejo"

FORGE_PASSWORD=$(secret forge-password 12)
if ! forgejo admin user list | awk 'NR > 1 {print $2}' | grep -qx "$FORGE_USER"; then
  forgejo admin user create --admin --username "$FORGE_USER" --email "$FORGE_EMAIL" \
    --password "$FORGE_PASSWORD" --must-change-password=false >/dev/null
fi

# write:package includes read: the pipeline pushes with it, k3s pulls with it.
if [[ ! -s $SECRETS/registry-token ]]; then
  (umask 077; forgejo admin user generate-access-token --username "$FORGE_USER" \
    --token-name ci-registry --scopes write:package --raw > "$SECRETS/registry-token")
fi
REGISTRY_TOKEN=$(cat "$SECRETS/registry-token")

# HTTPS through Caddy proves DNS, ports 80/443 and the certificate together.
echo "waiting for https://git.$DOMAIN (Let's Encrypt certificate)"
for i in $(seq 60); do curl -fsS -o /dev/null "https://git.$DOMAIN/api/healthz" && break; sleep 5; done
curl -fsS -o /dev/null "https://git.$DOMAIN/api/healthz" ||
  die "https://git.$DOMAIN unreachable: check that git.$DOMAIN points here and ports 80/443 are open (docker compose -f $STATE/forge/compose.yaml logs caddy)"

# Idempotent on the Forgejo side: the same secret updates the same runner.
RUNNER_SECRET=$(secret runner-secret 20)
forgejo forgejo-cli actions register --name "$(hostname)" --labels host --secret "$RUNNER_SECRET" >/dev/null

# --- Pinned binaries ----------------------------------------------------------

step "kubectl, Go, forgejo-runner, k3s"
k8s=https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/amd64/kubectl
[[ $(/usr/local/bin/kubectl version --client -o json 2>/dev/null | jq -r .clientVersion.gitVersion) == "$KUBECTL_VERSION" ]] ||
  fetch "$k8s" /usr/local/bin/kubectl "$(sha_of "$k8s.sha256")"

if [[ $(/usr/local/go/bin/go env GOVERSION 2>/dev/null) != "go$GO_VERSION" ]]; then
  go_url=https://dl.google.com/go/go$GO_VERSION.linux-amd64.tar.gz
  tmp=$(mktemp)
  curl -fsSL -o "$tmp" "$go_url"
  echo "$(sha_of "$go_url.sha256")  $tmp" | sha256sum -c --quiet - || die "checksum mismatch for $go_url"
  rm -rf /usr/local/go && tar -C /usr/local -xzf "$tmp" && rm -f "$tmp"
fi
echo 'export PATH=/usr/local/go/bin:$PATH' > /etc/profile.d/go.sh

runner_url=https://code.forgejo.org/forgejo/runner/releases/download/v$FORGEJO_RUNNER_VERSION/forgejo-runner-$FORGEJO_RUNNER_VERSION-linux-amd64
[[ $(/usr/local/bin/forgejo-runner --version 2>/dev/null) == *"$FORGEJO_RUNNER_VERSION"* ]] ||
  fetch "$runner_url" /usr/local/bin/forgejo-runner "$(sha_of "$runner_url.sha256")"

# k3s system images (Traefik, CoreDNS, ...) from GitHub instead of Docker Hub,
# whose anonymous pull limit is per IP.
k3s_rel=https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION/+/%2B}
k3s_sums=$(curl -fsSL "$k3s_rel/sha256sum-amd64.txt")
k3s_sha() { awk -v f="$1" '$2 == f {print $1}' <<<"$k3s_sums"; }
mkdir -p /etc/rancher/k3s /var/lib/rancher/k3s/agent/images /var/lib/rancher/k3s/server/manifests
airgap=/var/lib/rancher/k3s/agent/images/k3s-airgap-images-amd64.tar.zst
[[ -f $airgap ]] && echo "$(k3s_sha k3s-airgap-images-amd64.tar.zst)  $airgap" | sha256sum -c --quiet - 2>/dev/null ||
  { fetch "$k3s_rel/k3s-airgap-images-amd64.tar.zst" "$airgap" "$(k3s_sha k3s-airgap-images-amd64.tar.zst)"; chmod 0644 "$airgap"; }
[[ -f /usr/local/bin/k3s ]] && echo "$(k3s_sha k3s)  /usr/local/bin/k3s" | sha256sum -c --quiet - 2>/dev/null ||
  fetch "$k3s_rel/k3s" /usr/local/bin/k3s "$(k3s_sha k3s)"

printf 'write-kubeconfig-mode: "0600"\n' > /etc/rancher/k3s/config.yaml
install -m 0600 "$HERE/manifests/traefik-config.yaml" /var/lib/rancher/k3s/server/manifests/traefik-config.yaml
if [[ ! -f /etc/systemd/system/k3s.service ]]; then
  curl -fsSL -o /opt/k3s-install.sh "https://raw.githubusercontent.com/k3s-io/k3s/${K3S_VERSION/+/%2B}/install.sh"
  # Binary already in place: the script only writes the systemd unit and the
  # crictl/ctr symlinks (kubectl exists, so it leaves that alone).
  INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_VERSION=$K3S_VERSION sh /opt/k3s-install.sh
fi
for i in $(seq 60); do $KUBECTL wait --for=condition=Ready node --all --timeout=5s >/dev/null 2>&1 && break; sleep 5; done
$KUBECTL wait --for=condition=Ready node --all --timeout=5s >/dev/null || die "k3s node not Ready: journalctl -u k3s"

# --- Infrastructure (namespace infra) -----------------------------------------

step "PostgreSQL, Kafka, otel-lgtm"
export POSTGRES_PASSWORD; POSTGRES_PASSWORD=$(secret postgres 16)
render "$HERE/manifests/infra.yaml" NAME POSTGRES_PASSWORD POSTGRES_IMAGE KAFKA_IMAGE OTEL_LGTM_IMAGE | $KUBECTL apply -f -
for r in statefulset/postgres statefulset/kafka deployment/otel-lgtm; do
  $KUBECTL -n infra rollout status "$r" --timeout=300s
done

# One role + database per service, plus Hydra's; CREATE only what is missing.
HYDRA_DB_PASSWORD=$(secret db-hydra 16)
declare -A DB_PASSWORD
for s in "${SERVICES[@]}"; do DB_PASSWORD[$s]=$(secret "db-$s" 16); done
{
  echo '\set ON_ERROR_STOP on'
  echo 'CREATE TEMP TABLE want(r text, p text);'
  printf "INSERT INTO want VALUES ('hydra', '%s')" "$HYDRA_DB_PASSWORD"
  for s in "${SERVICES[@]}"; do printf ", ('%s_%s', '%s')" "$NAME" "$s" "${DB_PASSWORD[$s]}"; done
  echo ';'
  cat <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', r, p) FROM want
  WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) \gexec
SET client_min_messages = warning;
SELECT format('ALTER ROLE %I PASSWORD %L', r, p) FROM want \gexec
SELECT format('CREATE DATABASE %I OWNER %I', r, r) FROM want
  WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = r) \gexec
SQL
} | $KUBECTL -n infra exec -i statefulset/postgres -- psql -q -U postgres -d postgres >/dev/null

kafka_topics() { $KUBECTL -n infra exec statefulset/kafka -- /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 "$@"; }
kafka_topics --list | grep -qx "$NAME.transfer-events" ||
  kafka_topics --create --topic "$NAME.transfer-events" --partitions 3 --replication-factor 1

step "Hydra"
export HYDRA_DB_PASSWORD HYDRA_SYSTEM_SECRET; HYDRA_SYSTEM_SECRET=$(secret hydra-system 32)
render "$HERE/manifests/hydra.yaml" DOMAIN HYDRA_DB_PASSWORD HYDRA_SYSTEM_SECRET HYDRA_IMAGE | $KUBECTL apply -f -
$KUBECTL -n infra rollout status deployment/hydra --timeout=300s

# The same grants as hydra-init in compose.yaml, ids prefixed with NAME.
TRANSFER_CLIENT_SECRET=$(secret oauth-transfer-service 16)
CHANNEL_CLIENT_SECRET=$(secret oauth-channel-app 16)
$KUBECTL -n infra exec -i deployment/hydra -- sh -eu <<EOF
export ORY_SDK_URL=http://localhost:4445
ensure() {
  hydra get oauth2-client "\$1" >/dev/null 2>&1 && return 0
  hydra create oauth2-client --id "\$1" --secret "\$2" \
    --grant-type client_credentials --response-type token \
    --scope "\$3" --access-token-strategy jwt --quiet >/dev/null
  echo "created client \$1"
}
ensure $NAME-transfer-service '$TRANSFER_CLIENT_SECRET' account:read,account:write
ensure $NAME-channel-app '$CHANNEL_CLIENT_SECRET' transfer:read,transfer:write
EOF

# --- Namespace for the pipeline -----------------------------------------------

step "Namespace $NAME"
export DOCKER_CONFIG_JSON TRANSFER_CLIENT_SECRET DB_ACCOUNT_PASSWORD DB_TRANSFER_PASSWORD DB_NOTIFICATION_PASSWORD
DOCKER_CONFIG_JSON=$(jq -cn --arg h "git.$DOMAIN" --arg u "$FORGE_USER" --arg p "$REGISTRY_TOKEN" \
  '{auths: {($h): {username: $u, password: $p, auth: ("\($u):\($p)" | @base64)}}}')
DB_ACCOUNT_PASSWORD=${DB_PASSWORD[account]}
DB_TRANSFER_PASSWORD=${DB_PASSWORD[transfer]}
DB_NOTIFICATION_PASSWORD=${DB_PASSWORD[notification]}
render "$HERE/manifests/namespace.yaml" NAME DOCKER_CONFIG_JSON TRANSFER_CLIENT_SECRET \
  DB_ACCOUNT_PASSWORD DB_TRANSFER_PASSWORD DB_NOTIFICATION_PASSWORD | $KUBECTL apply -f -

for i in $(seq 30); do
  SA_TOKEN=$($KUBECTL -n "$NAME" get secret deployer-token -o jsonpath='{.data.token}' | base64 -d)
  [[ -n $SA_TOKEN ]] && break; sleep 2
done
[[ -n $SA_TOKEN ]] || die "no token in secret deployer-token of namespace $NAME"

# Limited to the namespace: the repository secret KUBE_CONFIG, and root's
# kubectl on this server (the admin kubeconfig stays in $ADMIN_KUBECONFIG).
(umask 077; cat > "$STATE/kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: lab10
    cluster:
      server: https://127.0.0.1:6443
      certificate-authority-data: $(base64 -w0 /var/lib/rancher/k3s/server/tls/server-ca.crt)
users:
  - name: $NAME
    user:
      token: $SA_TOKEN
contexts:
  - name: $NAME
    context:
      cluster: lab10
      user: $NAME
      namespace: $NAME
current-context: $NAME
EOF
)
install -d -m 0700 /root/.kube
install -m 0600 "$STATE/kubeconfig" /root/.kube/config

# --- Runner -------------------------------------------------------------------

step "Runner"
id runner >/dev/null 2>&1 || useradd --create-home --shell /bin/bash --groups docker runner
install -d -o runner -g runner -m 0750 /home/runner/work
install -d -m 0755 /etc/forgejo-runner
install -m 0644 "$HERE/runner-config.yml" /etc/forgejo-runner/config.yml
install -m 0644 "$HERE/forgejo-runner.service" /etc/systemd/system/forgejo-runner.service
[[ -f /home/runner/.runner ]] ||
  (cd /home/runner && sudo -u runner /usr/local/bin/forgejo-runner create-runner-file \
    --instance "https://git.$DOMAIN" --name "$(hostname)" --secret "$RUNNER_SECRET")
systemctl daemon-reload
systemctl enable forgejo-runner >/dev/null
systemctl restart forgejo-runner

# --- Values for the lab -------------------------------------------------------

step "Done"
(umask 077; cat > /root/lab10.txt <<EOF
Lab 10 di server sendiri: nilai untuk $NAME
==========================================

Git server         : https://git.$DOMAIN
  username         : $FORGE_USER
  password         : $FORGE_PASSWORD
kubectl (root)     : ~/.kube/config hanya berlaku di namespace $NAME
                     admin: KUBECONFIG=$ADMIN_KUBECONFIG kubectl ...

Repository baru di git server: $FORGE_USER/training-microservices-2026-01
Settings -> Actions -> Variables:
  REGISTRY           git.$DOMAIN
  NAMESPACE          $NAME
Settings -> Actions -> Secrets:
  REGISTRY_USER      $FORGE_USER
  REGISTRY_PASSWORD  $REGISTRY_TOKEN
  KUBE_CONFIG        isi file $STATE/kubeconfig  (cat $STATE/kubeconfig)

Pengganti replace-me di studi-kasus/k8s/overlays/server:
  https://auth.replace-me.invalid/...       -> https://auth.$DOMAIN/...
  kafka.replace-me.invalid:9092             -> kafka.infra.svc.cluster.local:9092
  http://otel.replace-me.invalid:4317       -> http://otel.infra.svc.cluster.local:4317
  replace-me.transfer-events                -> $NAME.transfer-events
  replace-me-transfer-service               -> $NAME-transfer-service
  replace-me.notification                   -> $NAME.notification
  replace-me.app.replace-me.invalid         -> app.$DOMAIN

Sekaligus dengan GNU sed (Linux), dari root repository:
  sed -i -e 's#auth\.replace-me\.invalid#auth.$DOMAIN#g' \\
         -e 's#\(kafka\|otel\)\.replace-me\.invalid#\1.infra.svc.cluster.local#g' \\
         -e 's#replace-me\.app\.replace-me\.invalid#app.$DOMAIN#g' \\
         -e 's#replace-me#$NAME#g' \\
         studi-kasus/k8s/overlays/server/config.yaml studi-kasus/k8s/overlays/server/ingress.yaml

Client OAuth2 channel-app (untuk memanggil REST transfer):
  client id     : $NAME-channel-app
  client secret : $CHANNEL_CLIENT_SECRET
  token         : curl -sS -u $NAME-channel-app:$CHANNEL_CLIENT_SECRET -d grant_type=client_credentials \\
                    -d 'scope=transfer:read transfer:write' https://auth.$DOMAIN/oauth2/token

Membuat rekening (REST account tidak lewat Ingress), di server ini:
  kubectl port-forward svc/account 28081:8081 &
  curl -sS -X POST localhost:28081/accounts \\
    -d '{"number":"1000000001","owner_name":"Satu","initial_balance":"1000000"}'

Transfer lewat Ingress:
  curl -sS -X POST https://app.$DOMAIN/transfers -H "Authorization: Bearer \$TOKEN" \\
    -d '{"from_account":"1000000001","to_account":"1000000002","amount":"150000"}'
EOF
)
cat /root/lab10.txt
