#!/usr/bin/env bash
# End-to-end check of the Lab 9/10 setup on k3d, run by
# .github/workflows/e2e-k3d.yaml after make infra-up, images, k3d-up,
# k3d-import and k8s-apply. Also runs on a laptop in the same state.
# Called through the Makefile (make e2e-smoke, e2e-rolling-update, e2e-dump),
# which passes K3D_NAMESPACE.
#
#   smoke           two new accounts, a transfer through the Ingress
#                   (localhost:8080) answered 201 COMPLETED, and its
#                   notification row in db-notification
#   rolling-update  make pipeline-k3d SERVICE=transfer (test, image tagged
#                   with the commit, k3d import, deploy) while a request loop
#                   posts transfers through the Ingress; fails on any answer
#                   that is not 2xx, or when no request was made
#   dump            pods, events, logs and docker compose logs, for a failed run
set -euo pipefail

: "${K3D_NAMESPACE:?K3D_NAMESPACE is required (make passes it)}"
INGRESS_URL=http://localhost:8080
ACCOUNT_PORT=8081
NS=$K3D_NAMESPACE

# Account REST is not behind the Ingress (README, Lab 9): reach it through
# kubectl port-forward for as long as the calling command runs.
start_account_forward() {
	kubectl -n "$NS" port-forward svc/account "$ACCOUNT_PORT:$ACCOUNT_PORT" >/dev/null &
	FORWARD_PID=$!
	trap 'kill "$FORWARD_PID" 2>/dev/null || true' EXIT
	for _ in $(seq 30); do
		curl -fsS -o /dev/null "http://localhost:$ACCOUNT_PORT/healthz" 2>/dev/null && return 0
		sleep 1
	done
	echo "account not reachable through port-forward after 30 s" >&2
	exit 1
}

# create_account <number> <balance>: fails unless account answers 201.
create_account() {
	local code
	code=$(curl -sS -o /dev/stderr -w '%{http_code}' -X POST "http://localhost:$ACCOUNT_PORT/accounts" \
		-d "{\"number\":\"$1\",\"owner_name\":\"E2E $1\",\"initial_balance\":\"$2\"}")
	echo >&2
	[ "$code" = 201 ] || { echo "create account $1: HTTP $code, expected 201" >&2; exit 1; }
}

# Two new 10-digit account numbers from the clock, 1... and 2..., so a later
# run against the same database does not hit existing accounts (409).
new_accounts() {
	local t
	t=$(( $(date +%s) % 1000000000 ))
	FROM=$(printf '1%09d' "$t")
	TO=$(printf '2%09d' "$t")
	create_account "$FROM" "$1"
	create_account "$TO" 0
}

# rollout status returns once the pods are Ready, but Traefik picks up the new
# endpoints a moment later; a request in between gets an empty reply. Wait
# until the transfer service itself answers through the Ingress: without a
# token its JWT middleware answers 401, which Traefik never produces.
wait_ingress() {
	local code
	for _ in $(seq 60); do
		code=$(curl -s -o /dev/null -w '%{http_code}' "$INGRESS_URL/transfers/00000000-0000-0000-0000-000000000000" || true)
		[ "$code" = 401 ] && return 0
		sleep 1
	done
	echo "transfer not reachable through the Ingress after 60 s (last HTTP code: $code)" >&2
	exit 1
}

# --no-print-directory: under make -C the outer make passes -w to every
# nested make, whose "Entering directory" lines would end up in the token.
smoke() {
	wait_ingress
	start_account_forward
	new_accounts 1000000
	local token resp code body id
	token=$(make -s --no-print-directory token)
	resp=$(curl -sS -w '\n%{http_code}' -X POST "$INGRESS_URL/transfers" -H "Authorization: Bearer $token" \
		-d "{\"from_account\":\"$FROM\",\"to_account\":\"$TO\",\"amount\":\"150000\"}")
	code=${resp##*$'\n'}
	body=${resp%$'\n'*}
	echo "POST /transfers: HTTP $code $body"
	[ "$code" = 201 ] || { echo "expected HTTP 201" >&2; exit 1; }
	case "$body" in *'"status":"COMPLETED"'*) ;; *) echo "expected status COMPLETED" >&2; exit 1;; esac
	id=$(echo "$body" | sed -E 's/.*"id":"([^"]+)".*/\1/')
	# The event goes transfer outbox -> Kafka -> notification -> db-notification.
	for _ in $(seq 30); do
		n=$(docker compose exec -T db-notification psql -U notification -d notification -tAc \
			"select count(*) from notification where transfer_id = '$id'")
		if [ "$n" -ge 1 ]; then
			echo "notification for transfer $id: $n row(s)"
			return 0
		fi
		sleep 1
	done
	echo "no notification row for transfer $id after 30 s" >&2
	exit 1
}

rolling_update() {
	start_account_forward
	new_accounts 100000000
	local token work loop_pid total bad
	token=$(make -s --no-print-directory token)
	work=$(mktemp -d)
	# One transfer every 0.2 s through the Ingress until the stop file exists;
	# 000 = no HTTP answer at all (connection refused or reset, timeout).
	(
		while [ ! -e "$work/stop" ]; do
			curl -s -o /dev/null -w '%{http_code}\n' -m 10 -X POST "$INGRESS_URL/transfers" \
				-H "Authorization: Bearer $token" \
				-d "{\"from_account\":\"$FROM\",\"to_account\":\"$TO\",\"amount\":\"1000\"}" >> "$work/codes" || true
			sleep 0.2
		done
	) &
	loop_pid=$!
	make pipeline-k3d SERVICE=transfer
	# A few more requests against the new pod only.
	sleep 5
	touch "$work/stop"
	wait "$loop_pid"
	echo "responses during the rolling update (count, HTTP status):"
	sort "$work/codes" | uniq -c
	total=$(wc -l < "$work/codes")
	bad=$(grep -vc '^2' "$work/codes" || true)
	rm -rf "$work"
	kubectl -n "$NS" rollout history deployment/transfer
	kubectl -n "$NS" get deployment/transfer -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
	[ "$total" -gt 0 ] || { echo "no request was made during the rolling update" >&2; exit 1; }
	[ "$bad" -eq 0 ] || { echo "$bad of $total requests were not answered 2xx during the rolling update" >&2; exit 1; }
	echo "$total requests, all 2xx"
}

# Diagnostics only: every command runs even when an earlier one fails.
dump() {
	set +e
	kubectl -n "$NS" get deployments,replicasets,pods,services,ingress -o wide
	kubectl -n "$NS" get events --sort-by=.lastTimestamp
	for d in account transfer notification; do
		echo "=== logs deployment/$d"
		kubectl -n "$NS" logs "deployment/$d" --all-containers --tail=200
		kubectl -n "$NS" describe pods -l "app.kubernetes.io/name=$d"
	done
	docker compose ps -a
	docker compose logs --tail=200
	return 0
}

case "${1:-}" in
smoke) smoke ;;
rolling-update) rolling_update ;;
dump) dump ;;
*) echo "usage: $0 smoke|rolling-update|dump" >&2; exit 1 ;;
esac
