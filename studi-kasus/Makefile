SERVICES := account transfer notification

# Fault injection on the account service (Lab 3). Faults apply to REST /accounts*
# and, from Lab 4, to the gRPC AccountService; probes, gRPC health and /admin
# stay fast.
ACCOUNT_URL := http://localhost:8081
TRANSFER_URL := http://localhost:8082
NOTIFICATION_URL := http://localhost:8083

HYDRA_URL := http://localhost:4444

KAFKA_TOPIC := transfer-events
KAFKA_BIN := /opt/kafka/bin

.PHONY: infra-up infra-down infra-reset test proto fault-slow fault-error fault-clear fault-status breaker \
	events outbox replay duplicates token metrics apps-up apps-down images k3d-up k3d-import k8s-apply k3d-down \
	pipeline-k3d k8s-apply-server e2e-smoke e2e-rolling-update e2e-dump

# kafka-init creates the topic (idempotent: --if-not-exists); hydra-init
# (re)creates the OAuth2 clients, which Hydra's in-memory storage loses on every
# restart.
infra-up:
	docker compose up -d --wait
	docker compose run --rm kafka-init
	docker compose run --rm hydra-init

# --profile init/apps: down skips services of inactive profiles, and a leftover
# kafka-init or service container would keep the network from being removed.
infra-down:
	docker compose --profile init --profile apps down

# Removes the database and Kafka volumes too: all lab data is lost.
infra-reset:
	docker compose --profile init --profile apps down -v

test:
	$(MAKE) -C proto test
	@for s in $(SERVICES); do $(MAKE) -C $$s test || exit 1; done

# Regenerates proto/gen after a .proto change (Lab 4). Needs protoc,
# protoc-gen-go and protoc-gen-go-grpc.
proto:
	$(MAKE) -C proto generate

# 3000 ms is above the transfer client's 2 s per-attempt timeout: every call
# times out and counts as a breaker failure.
fault-slow:
	curl -sS -X PUT $(ACCOUNT_URL)/admin/fault -d '{"delay_ms":3000,"error_rate":0}'

# Usage: make fault-error RATE=0.5 (fraction of requests answered HTTP 503 /
# gRPC Unavailable).
fault-error:
	@test -n "$(RATE)" || { echo "RATE is required, e.g. make fault-error RATE=0.5" >&2; exit 1; }
	curl -sS -X PUT $(ACCOUNT_URL)/admin/fault -d '{"delay_ms":0,"error_rate":$(RATE)}'

fault-clear:
	curl -sS -X DELETE $(ACCOUNT_URL)/admin/fault

fault-status:
	curl -sS $(ACCOUNT_URL)/admin/fault

breaker:
	curl -sS $(TRANSFER_URL)/debug/circuit-breaker

# Lab 5 helpers.

# Prints every event on the topic with its partition, headers and key, then
# exits after 5 s without new events (that exit is logged as a TimeoutException
# by the console consumer; it is not an error).
events:
	docker compose exec kafka $(KAFKA_BIN)/kafka-console-consumer.sh --bootstrap-server localhost:9092 \
		--topic $(KAFKA_TOPIC) --from-beginning --timeout-ms 5000 \
		--property print.key=true --property print.headers=true --property print.partition=true

# The newest outbox rows in the transfer database; published_at empty = not on Kafka yet.
outbox:
	docker compose exec db-transfer psql -U transfer -d transfer -c \
		"select id, aggregate_id, event_type, created_at, published_at from outbox order by created_at desc limit 20"

# Rewinds the notification consumer group to the first event, so every event is
# delivered again. Kafka only resets a group without active members: stop the
# notification service first.
replay:
	docker compose exec kafka $(KAFKA_BIN)/kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
		--group notification --topic $(KAFKA_TOPIC) --reset-offsets --to-earliest --execute

# Lab 6: events with more than one notification. Empty after a replay = the
# consumer is idempotent. Rows from Lab 5 (before processed_event) stay listed.
duplicates:
	docker compose exec db-notification psql -U notification -d notification -c \
		"select event_id, event_type, count(*) as notifications from notification group by event_id, event_type having count(*) > 1"

# Lab 7: prints an access token of the channel-app client (scopes transfer:read
# transfer:write), valid for 1 hour. Usage:
#   TOKEN=$(make -s token)
#   curl -H "Authorization: Bearer $TOKEN" localhost:8082/transfers/<id>
# SCOPE narrows it, e.g. make -s token SCOPE=transfer:read.
SCOPE := transfer:read transfer:write
token:
	@resp=$$(curl -sS -u channel-app:channel-app-secret -d grant_type=client_credentials -d "scope=$(SCOPE)" \
		$(HYDRA_URL)/oauth2/token) || exit 1; \
	case "$$resp" in *'"access_token"'*) ;; *) echo "$$resp" >&2; exit 1;; esac; \
	echo "$$resp" | sed -E 's/.*"access_token":"([^"]+)".*/\1/'

# Lab 8: the domain metrics of the three services, straight from their
# /metrics endpoints (what Prometheus scrapes every 5 s). Grafana:
# http://localhost:3000, dashboard "Studi Kasus: Transfer".
metrics:
	@for u in $(ACCOUNT_URL) $(TRANSFER_URL) $(NOTIFICATION_URL); do \
		echo "# $$u/metrics"; \
		curl -sS $$u/metrics | grep -E '^(transfers_total|circuit_breaker_|outbox_pending|notifications_processed_total)' || true; \
	done

# Lab 9 helpers.

# The three services as containers next to the infrastructure (compose profile
# apps), rebuilt from the Dockerfiles. Run make infra-up first, and stop the
# services started with make -C <service> run: the ports are the same.
apps-up:
	docker compose --profile apps up -d --build account transfer notification

apps-down:
	docker compose --profile apps rm -sf account transfer notification

# Images for k3d. VERSION is the tag, e.g. make images VERSION=1.0.0, and is
# required: the image name says which build it is. Nothing stops a rebuild under
# an existing tag, and it rolls nothing: the image reference is unchanged, so
# running pods keep the old image while pods created later (after another
# k3d-import) get the new one. A change = a new VERSION (1.0.1), make k3d-import
# with it, then
# kubectl set image or newTag in k8s/overlays/k3d/kustomization.yaml.
# Build context is this directory: account and transfer copy proto/ next to the
# service (go.mod replace ../proto); notification does not import it.
IMAGE_REPO := studi-kasus
CLUSTER := bank
# K3D_NAMESPACE, not NAMESPACE: pipeline.mk takes NAMESPACE from the caller,
# and a top-level value would be passed on to it.
K3D_NAMESPACE := bank
IMAGES = $(foreach s,$(SERVICES),$(IMAGE_REPO)/$(s):$(VERSION))

images:
	@test -n "$(VERSION)" || { echo "VERSION is required, e.g. make images VERSION=1.0.0" >&2; exit 1; }
	@for s in $(SERVICES); do docker build -f $$s/Dockerfile -t $(IMAGE_REPO)/$$s:$(VERSION) . || exit 1; done

# One server node; port 8080 on the laptop goes to the cluster's ingress
# controller (Traefik, port 80). The k3s image is pinned; k3d itself pulls its
# helper images (k3d-proxy, k3d-tools) in the version of the k3d binary.
# k3d writes host.k3d.internal into the CoreDNS ConfigMap, but CoreDNS answers
# for it only after the ConfigMap reaches its pod, up to a minute later; pods
# started before that crash with "lookup host.k3d.internal ... no such host".
# So k3d-up waits until the cluster DNS (k3s default 10.43.0.10) resolves the
# name, asked from the server node container (its image has nslookup).
k3d-up:
	k3d cluster create $(CLUSTER) --image rancher/k3s:v1.36.5-k3s1 -p 8080:80@loadbalancer
	@echo "waiting until the cluster DNS resolves host.k3d.internal"
	@for i in $$(seq 90); do \
		docker exec k3d-$(CLUSTER)-server-0 nslookup host.k3d.internal 10.43.0.10 >/dev/null 2>&1 && exit 0; \
		sleep 2; \
	done; \
	echo "host.k3d.internal does not resolve in the cluster DNS after 180 s" >&2; exit 1

# Copies the images from the local Docker into the cluster's containerd, so no
# registry is needed (Lab 10 pushes to one).
k3d-import:
	@test -n "$(VERSION)" || { echo "VERSION is required, e.g. make k3d-import VERSION=1.0.0" >&2; exit 1; }
	$(call k3d-load,$(IMAGES))

# $(call k3d-load,IMAGE ...) imports images into the cluster and checks that
# the node's containerd really has each one (crictl resolves the name the way
# the kubelet does). k3d image import can report success while an image never
# arrives; the pod then tries to pull it from the network (ImagePullBackOff).
# A missing image is imported once more, directly into the node.
K3D_NODE = k3d-$(CLUSTER)-server-0
k3d-load = k3d image import -c $(CLUSTER) $(1) && \
	for img in $(1); do \
		docker exec $(K3D_NODE) crictl inspecti -q $$img >/dev/null 2>&1 && continue; \
		echo "$$img not found in the cluster after import, importing again" >&2; \
		k3d image import --mode direct -c $(CLUSTER) $$img && \
		docker exec $(K3D_NODE) crictl inspecti -q $$img >/dev/null 2>&1 || \
		{ echo "$$img is not in cluster $(CLUSTER) after two imports" >&2; exit 1; }; \
	done

# Applies the k3d overlay, then waits until every Deployment is rolled out
# (readiness probes pass) or reports which one is not.
k8s-apply:
	kubectl apply -k k8s/overlays/k3d
	@for s in $(SERVICES); do kubectl -n $(K3D_NAMESPACE) rollout status deployment/$$s --timeout=120s || exit 1; done

k3d-down:
	k3d cluster delete $(CLUSTER)

# Lab 10 helpers. The pipeline itself is in .forgejo/workflows (git server's
# runner) and <service>/Jenkinsfile; its steps are the targets image, push and
# deploy in pipeline.mk.

# The pipeline of one service on the laptop, against k3d: test, image, then
# k3d image import in place of push (no registry on the laptop), then deploy.
# Usage: make pipeline-k3d SERVICE=transfer (after make k8s-apply of Lab 9).
# The tag is the current commit, as in the pipeline; uncommitted changes would
# end up in an image whose tag names a commit without them, so commit first.
# A later make k8s-apply sets the images back to the tag in overlays/k3d.
PIPELINE_REGISTRY := k3d.local
pipeline-k3d:
	@test -n "$(SERVICE)" || { echo "SERVICE is required, e.g. make pipeline-k3d SERVICE=transfer" >&2; exit 1; }
	@test -z "$$(git status --porcelain -- .)" || { echo "uncommitted changes in studi-kasus/: commit first, the image tag is the commit" >&2; exit 1; }
	@v=$$(git rev-parse --short=12 HEAD) && \
	$(MAKE) -C $(SERVICE) test && \
	$(MAKE) -C $(SERVICE) image REGISTRY=$(PIPELINE_REGISTRY) IMAGE_OWNER=$(IMAGE_REPO) VERSION=$$v && \
	$(call k3d-load,$(PIPELINE_REGISTRY)/$(IMAGE_REPO)/$(SERVICE):$$v) && \
	$(MAKE) -C $(SERVICE) deploy REGISTRY=$(PIPELINE_REGISTRY) IMAGE_OWNER=$(IMAGE_REPO) VERSION=$$v NAMESPACE=$(K3D_NAMESPACE)

# The server overlay for one service, the same apply that the pipeline's
# first deploy runs (make apply in pipeline.mk): to bring a change in
# k8s/overlays/server (config.yaml, ingress.yaml) to the cluster. VERSION is
# the image to keep or to roll out, usually the commit already deployed
# (kubectl rollout history). Pods read ConfigMaps only at start: kubectl
# rollout restart deployment/<service> after a config change.
# Refuses while a placeholder is left: the instructor hands out the training
# server's addresses (~/lab10.txt on the server).
# Usage: make k8s-apply-server SERVICE=transfer VERSION=<sha> REGISTRY=...
#        IMAGE_OWNER=... NAMESPACE=...  (KUBECONFIG of the training server)
k8s-apply-server:
	@test -n "$(SERVICE)" || { echo "SERVICE is required, e.g. make k8s-apply-server SERVICE=transfer VERSION=<sha>" >&2; exit 1; }
	$(MAKE) -C $(SERVICE) apply

# End-to-end check on k3d, used by .github/workflows/e2e-k3d.yaml after
# infra-up, images, k3d-up, k3d-import and k8s-apply (e2e-k3d.sh has the
# details). e2e-rolling-update runs pipeline-k3d SERVICE=transfer under a
# request loop through the Ingress and fails on any non-2xx answer; commit
# first, as for pipeline-k3d. e2e-dump prints pods, events and logs of a
# failed run.
e2e-smoke e2e-rolling-update e2e-dump:
	K3D_NAMESPACE=$(K3D_NAMESPACE) ./e2e-k3d.sh $(@:e2e-%=%)
