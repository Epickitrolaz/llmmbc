#!/usr/bin/env bash
# End-to-end test for the LLMMBC Docker cluster (docs/ARCHITECTURE.md §2-§4, §8).
#
# Brings up four nodes on one bridge network, lets the two workers pull their own
# copies of the two test models, then asserts:
#   * every node discovers the other three (broadcast or /24 subnet sweep),
#   * `llmmbc_node chat ... --node http://node-c:47101` returns a non-empty answer,
#   * GET /v1/session on the coordinator lists exactly node-a and node-b,
#   * the same flow works for the MoE model granite3.1-moe:1b.
#
# On failure it prints container state and logs, and exits non-zero.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
COMPOSE_FILE="${SCRIPT_DIR}/compose.yaml"
export LLMMBC_E2E_CACHE="${LLMMBC_E2E_CACHE:-${SCRIPT_DIR}/.cache}"

COMPOSE=(docker compose -f "${COMPOSE_FILE}" --project-name llmmbc-e2e)
NODE_SERVICES=(node-a node-b node-c node-d)
DENSE_MODEL=qwen3:0.6b
MOE_MODEL=granite3.1-moe:1b
CHAT_ANSWER=

log() { printf '\n=== %s\n' "$*"; }
die() { printf '::error::%s\n' "$*" >&2; exit 1; }

on_exit() {
  local status=$?
  set +e
  if ((status != 0)); then
    printf '\n=== FAILURE (exit %d): container state and logs\n' "${status}"
    "${COMPOSE[@]}" ps
    "${COMPOSE[@]}" logs --no-color --tail=400
  elif [[ "${LLMMBC_E2E_KEEP:-0}" != "1" ]]; then
    log "Tearing down the cluster"
    "${COMPOSE[@]}" down --remove-orphans --timeout 10
  fi
  exit "${status}"
}
trap on_exit EXIT

retry() { # retry <timeout-seconds> <description> <command...>
  local timeout=$1 description=$2
  shift 2
  local deadline=$((SECONDS + timeout))
  while true; do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    if ((SECONDS >= deadline)); then
      printf '::error::timed out after %ss waiting for %s\n' "${timeout}" "${description}" >&2
      return 1
    fi
    sleep 3
  done
}

compact_json() { tr -d '[:space:]'; }

with_timeout() { # with_timeout <seconds> <command...>; no-op when coreutils timeout is absent
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "${seconds}" "$@"
  else
    "$@"
  fi
}

node_id() { # node_id <service>
  "${COMPOSE[@]}" exec -T "$1" curl -fsS "http://127.0.0.1:47101/v1/node" \
    | compact_json \
    | grep -o '"nodeId":"[^"]*"' \
    | head -n 1 \
    | cut -d'"' -f4
}

session_json() { # session_json <service>
  "${COMPOSE[@]}" exec -T "$1" curl -fsS "http://127.0.0.1:47101/v1/session" | compact_json
}

declare -A NODE_ID=()

wait_for_node_ids() {
  local deadline=$((SECONDS + 300)) svc id ok
  while ((SECONDS < deadline)); do
    ok=1
    for svc in "${NODE_SERVICES[@]}"; do
      if ! id=$(node_id "${svc}" 2>/dev/null) || [[ -z "${id}" ]]; then
        ok=0
        continue
      fi
      NODE_ID["${svc}"]="${id}"
    done
    if ((ok == 1)); then
      return 0
    fi
    sleep 3
  done
  die "nodes did not report their nodeId within 300s"
}

peers_contain() { # peers_contain <service> <expected-node-id>...
  local svc=$1
  shift
  local out id
  out=$("${COMPOSE[@]}" exec -T "${svc}" llmmbc_node peers) || return 1
  out=$(printf '%s' "${out}" | compact_json)
  for id in "$@"; do
    printf '%s' "${out}" | grep -qF "${id}" || return 1
  done
}

assert_peers() {
  local svc other
  for svc in "${NODE_SERVICES[@]}"; do
    local -a others=()
    for other in "${NODE_SERVICES[@]}"; do
      if [[ "${other}" != "${svc}" ]]; then
        others+=("${NODE_ID[${other}]}")
      fi
    done
    log "${svc}: discovering the other 3 nodes"
    if ! retry 240 "${svc} peer discovery" peers_contain "${svc}" "${others[@]}"; then
      "${COMPOSE[@]}" exec -T "${svc}" llmmbc_node peers || true
      die "${svc} did not discover all 3 peers"
    fi
  done
}

run_chat() { # run_chat <model>
  local model=$1 out
  out=$(with_timeout 900 "${COMPOSE[@]}" exec -T node-c \
    llmmbc_node chat "${model}" "What is 2+2?" --node "http://node-c:47101") || return 1
  if [[ -z "${out//[[:space:]]/}" ]]; then
    return 1
  fi
  CHAT_ANSWER=${out}
}

assert_chat() { # assert_chat <model>
  local model=$1
  log "chat ${model} through client-only node-c"
  if ! retry 300 "chat ${model}" run_chat "${model}"; then
    die "chat via node-c failed or returned an empty answer for ${model}"
  fi
  printf 'answer: %s\n' "${CHAT_ANSWER}"
}

assert_session() { # assert_session <model>
  local model=$1 sa sb a_coord b_coord coord_svc coord_id other_id json excluded
  sa=$(session_json node-a) || return 1
  sb=$(session_json node-b) || return 1

  # The coordinator's own view is the one whose coordinatorId is its own nodeId.
  # Workers may also expose their side of the session; that is not asserted here.
  a_coord=0
  b_coord=0
  if grep -qF "\"coordinatorId\":\"${NODE_ID[node-a]}\"" <<<"${sa}"; then a_coord=1; fi
  if grep -qF "\"coordinatorId\":\"${NODE_ID[node-b]}\"" <<<"${sb}"; then b_coord=1; fi
  if ((a_coord + b_coord != 1)); then
    printf '::error::expected exactly one of node-a/node-b to be the session coordinator\n' >&2
    printf 'node-a: %s\n' "${sa}" >&2
    printf 'node-b: %s\n' "${sb}" >&2
    return 1
  fi

  if ((a_coord == 1)); then
    coord_svc=node-a
    coord_id=${NODE_ID[node-a]}
    other_id=${NODE_ID[node-b]}
    json=${sa}
  else
    coord_svc=node-b
    coord_id=${NODE_ID[node-b]}
    other_id=${NODE_ID[node-a]}
    json=${sb}
  fi
  printf 'coordinator: %s (%s)\n' "${coord_svc}" "${coord_id}"

  if ! grep -qF "\"coordinatorId\":\"${coord_id}\"" <<<"${json}"; then
    printf '::error::session coordinatorId is not the expected node\n' >&2
    return 1
  fi
  if ! grep -qF "\"workerIds\":[\"${other_id}\"]" <<<"${json}"; then
    printf '::error::session workerIds is not exactly the other worker\n' >&2
    return 1
  fi
  if ! grep -qF "\"model\":\"${model}\"" <<<"${json}"; then
    printf '::error::session does not report model %s\n' "${model}" >&2
    return 1
  fi
  for excluded in node-c node-d; do
    if grep -qF "${NODE_ID[${excluded}]}" <<<"${json}"; then
      printf '::error::session wrongly contains excluded node %s\n' "${excluded}" >&2
      return 1
    fi
  done
  return 0
}

assert_session_with_retry() { # assert_session_with_retry <model>
  local model=$1
  log "GET /v1/session: exactly node-a + node-b serve ${model}"
  if ! retry 120 "session for ${model}" assert_session "${model}"; then
    assert_session "${model}" || true
    die "session membership assertion failed for ${model}"
  fi
}

restart_cluster() {
  log "Restarting the cluster to clear the active session"
  "${COMPOSE[@]}" down --remove-orphans --timeout 10
  "${COMPOSE[@]}" up -d --wait --wait-timeout 1800
  # nodeId is persisted under /data, so this also confirms the ids are stable.
  wait_for_node_ids
}

main() {
  command -v docker >/dev/null 2>&1 || die "docker is required"
  docker compose version >/dev/null 2>&1 || die "docker compose v2 is required"
  [[ -f "${COMPOSE_FILE}" ]] || die "missing ${COMPOSE_FILE}"

  local svc
  for svc in "${NODE_SERVICES[@]}"; do
    mkdir -p "${LLMMBC_E2E_CACHE}/${svc}"
  done
  # Cache dirs are bind-mounted into the non-root container user. Files created
  # by a previous run are already owned by that uid, so ignore chmod failures.
  chmod -R a+rwX "${LLMMBC_E2E_CACHE}" 2>/dev/null || true

  log "Building the node image and starting the 4-node cluster"
  "${COMPOSE[@]}" up -d --build --wait --wait-timeout 1800

  wait_for_node_ids
  assert_peers

  assert_chat "${DENSE_MODEL}"
  assert_session_with_retry "${DENSE_MODEL}"

  restart_cluster
  assert_peers
  assert_chat "${MOE_MODEL}"
  assert_session_with_retry "${MOE_MODEL}"

  log "All Docker E2E assertions passed"
}

main "$@"
