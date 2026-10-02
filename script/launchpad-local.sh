#!/usr/bin/env bash
# Local-only launchpad deployment. Forks FORK_URL with anvil (keeping its chain ID), deploys ScheduledLaunch,
# LockedLaunchLiquidity and LaunchRouter from anvil's unlocked development account, writes
# launchpad-manifest.json and the ABIs, and checks the manifest code hashes against the node.
# Set KEEP_ANVIL=1 to leave the fork running for end-to-end use. Never point this at a live chain.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${FORK_URL:?set FORK_URL to an RPC endpoint of the chain to fork}"
PORT="${ANVIL_PORT:-8545}"
RPC="http://127.0.0.1:${PORT}"
SENDER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 # anvil development account 0
FORK_BLOCK="${FORK_BLOCK:-$(cast block-number --rpc-url "$FORK_URL")}"
GIT_REVISION="$(git rev-parse HEAD)"
if ! git diff --quiet HEAD -- src script; then GIT_REVISION="${GIT_REVISION}-dirty"; fi

anvil --fork-url "$FORK_URL" --fork-block-number "$FORK_BLOCK" --port "$PORT" --silent &
ANVIL_PID=$!
[[ "${KEEP_ANVIL:-0}" == 1 ]] || trap 'kill "$ANVIL_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done

FORK_BLOCK="$FORK_BLOCK" GIT_REVISION="$GIT_REVISION" ABI_DIR=launchpad-abis \
  forge script --offline script/DeployLaunchpadLocal.s.sol --rpc-url "$RPC" --unlocked --sender "$SENDER" --broadcast

mkdir -p launchpad-abis
for c in ScheduledLaunch LockedLaunchLiquidity LaunchRouter Router; do
  jq .abi "out/${c}.sol/${c}.json" >"launchpad-abis/${c}.json"
done

# The script reverts unless the launch extension's TWAMM is the manifest's and Core has it registered.
[[ "$(jq -r .twamm_registered launchpad-manifest.json)" == true ]] || { echo "twamm_registered is not true" >&2; exit 1; }
for name in $(jq -r '.contracts | keys[]' launchpad-manifest.json); do
  address="$(jq -r ".contracts.${name}.address" launchpad-manifest.json)"
  expected="$(jq -r ".contracts.${name}.code_hash" launchpad-manifest.json)"
  actual="$(cast keccak "$(cast code "$address" --rpc-url "$RPC")")"
  [[ "$actual" == "$expected" ]] || { echo "code hash mismatch for ${name} at ${address}" >&2; exit 1; }
done
echo "launchpad-manifest.json written; chain $(cast chain-id --rpc-url "$RPC"), fork block ${FORK_BLOCK}, rpc ${RPC}"
[[ "${KEEP_ANVIL:-0}" == 1 ]] && wait "$ANVIL_PID"
