# Pipeline targets shared by the three service Makefiles (Lab 10). The
# workflows in .forgejo/workflows and the Jenkinsfile of each service call
# these targets and nothing else, so a laptop, the git server's runner and a
# Jenkins agent run the same commands.
#
# The including Makefile sets SERVICE. Everything else comes from the caller
# (command line or environment) and has no default: an image pushed to the
# wrong registry or a deploy into the wrong namespace is worse than a stopped
# pipeline.
#   REGISTRY       registry host, e.g. registry.example.com
#   IMAGE_OWNER    user or organization that owns the image in the registry
#   VERSION        image tag; the pipeline passes the commit SHA, so every
#                  commit has its own image and a tag is never overwritten
#   NAMESPACE      Kubernetes namespace of the deploy target
#   REGISTRY_USER, REGISTRY_PASSWORD   push credentials, environment only
#                  (a command-line argument shows up in the process list)

IMAGE = $(REGISTRY)/$(IMAGE_OWNER)/$(SERVICE):$(VERSION)

# $(call require,VAR ...) stops with the names of the empty variables, the
# same message style as the services' LoadConfig.
missing = $(strip $(foreach v,$(1),$(if $(strip $($(v))),,$(v))))
require = $(if $(call missing,$(1)),$(error missing required variables: $(call missing,$(1))))

.PHONY: image push apply deploy

# Build context is studi-kasus/ (..), as in Lab 9: the Dockerfile copies proto/
# next to the service. The revision label ties a running image back to its
# commit (docker inspect, or the registry UI).
image:
	$(call require,REGISTRY IMAGE_OWNER VERSION)
	docker build -f Dockerfile --label org.opencontainers.image.revision=$(VERSION) -t $(IMAGE) ..

# A throwaway DOCKER_CONFIG per call, removed when the recipe ends: the
# registry token is not left in the runner user's ~/.docker/config.json after
# the job. That is all it does. It is no isolation between participants on a
# shared runner: anyone who can edit a workflow runs commands on the runner
# host as the runner user, and can read whatever another job has on disk or in
# its environment while it runs.
# The local image is removed after a successful push: the registry has it,
# and on a shared runner one image per commit per participant fills the disk.
# The build cache stays, so the next build reuses unchanged layers.
push:
	$(call require,REGISTRY IMAGE_OWNER VERSION REGISTRY_USER REGISTRY_PASSWORD)
	@cfg=$$(mktemp -d) && trap 'rm -rf "$$cfg"' EXIT && \
	printf '%s' "$$REGISTRY_PASSWORD" | DOCKER_CONFIG="$$cfg" docker login $(REGISTRY) -u "$$REGISTRY_USER" --password-stdin && \
	DOCKER_CONFIG="$$cfg" docker push $(IMAGE)
	docker image rm $(IMAGE)

# Applies this service's part of OVERLAY into NAMESPACE with the image
# IMAGE: the ConfigMap, Service, Deployment (and Ingress of transfer). The
# overlay has no namespace and no image tag; a generated kustomization on top
# of it sets both, and kubectl apply -l keeps only the objects labelled with
# this service (the other services' Deployments would get an unresolved
# image). Refuses while the overlay still has a replace-me placeholder.
# make deploy calls it when the Deployment does not exist yet; make
# k8s-apply-server (top-level Makefile) calls it to bring a config change to
# the cluster.
# The generated kustomization lives in a temporary directory next to this
# Makefile, removed when the recipe ends: kustomize refuses an absolute path
# in resources, so the overlay is referenced relative to it.
OVERLAY := ../k8s/overlays/server
SELECTOR := app.kubernetes.io/name=$(SERVICE)

apply:
	$(call require,REGISTRY IMAGE_OWNER VERSION NAMESPACE)
	@if kubectl kustomize $(OVERLAY) | grep -n replace-me; then \
		echo "$(OVERLAY) still has replace-me placeholders (lines above)" >&2; exit 1; fi
	@k=$$(mktemp -d .apply.XXXXXX) && trap 'rm -rf "$$k"' EXIT && \
	printf '%s\n' \
		'apiVersion: kustomize.config.k8s.io/v1beta1' \
		'kind: Kustomization' \
		'namespace: $(NAMESPACE)' \
		'resources:' \
		'  - ../$(OVERLAY)' \
		'images:' \
		'  - name: studi-kasus/$(SERVICE)' \
		'    newName: $(REGISTRY)/$(IMAGE_OWNER)/$(SERVICE)' \
		'    newTag: "$(VERSION)"' > "$$k/kustomization.yaml" && \
	echo "apply $(OVERLAY) to namespace $(NAMESPACE), objects $(SELECTOR), image $(IMAGE)" && \
	kubectl -n $(NAMESPACE) apply -k "$$k" -l $(SELECTOR)

# Rolling update to the new image: the same "kubectl set image" + "rollout
# status" as the Lab 9 exercise. The first run of a service, in an empty
# namespace, creates the Deployment with make apply instead; set image then
# changes nothing and rollout status waits for the first pods.
# "get --ignore-not-found" prints nothing only when the Deployment does not
# exist; any other error (no access, cluster unreachable) stops here.
# The change-cause annotation is copied to the new ReplicaSet, so "kubectl
# rollout history" lists the version per revision. It comes after set image:
# the controller copies it to the ReplicaSet that is current at that moment,
# and annotating first would relabel the previous revision with the new
# version.
# A failed rollout fails the pipeline and leaves the old pods serving
# (maxUnavailable: 0); rolling back stays a human decision
# (kubectl rollout undo).
# kubectl uses KUBECONFIG; the pipeline points it at a kubeconfig that is
# limited to NAMESPACE.
deploy:
	$(call require,REGISTRY IMAGE_OWNER VERSION NAMESPACE)
	@d=$$(kubectl -n $(NAMESPACE) get deployment/$(SERVICE) --ignore-not-found -o name) || exit 1; \
	if [ -z "$$d" ]; then \
		echo "deployment/$(SERVICE) not in namespace $(NAMESPACE): first deploy, applying the overlay"; \
		$(MAKE) --no-print-directory apply || exit 1; \
	fi
	kubectl -n $(NAMESPACE) set image deployment/$(SERVICE) $(SERVICE)=$(IMAGE)
	kubectl -n $(NAMESPACE) annotate deployment/$(SERVICE) kubernetes.io/change-cause="$(SERVICE) $(VERSION)" --overwrite
	kubectl -n $(NAMESPACE) rollout status deployment/$(SERVICE) --timeout=180s
