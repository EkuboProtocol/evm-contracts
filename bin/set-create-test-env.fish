#!/usr/bin/env fish

# Sets the environment variables required by CreateTestTransactions.s.sol by
# pulling contract addresses from Foundry's run-latest.json for DeployAll.s.sol.
# Usage (must be sourced): `source bin/set-create-test-env.fish <chain-id>`

function __ekt_usage
    echo "Usage: source (status current-filename) <chain-id>" >&2
end

function __ekt_lookup_address --argument-names contract_name broadcast_file
    jq -er --arg name $contract_name '
        .transactions[]
        | select(.contractName == $name)
        | .contractAddress
    ' $broadcast_file
end

function __ekt_main
    if test (count $argv) -ne 1
        __ekt_usage
        return 1
    end

    if not type -q jq
        echo "Error: jq is required but not found in PATH." >&2
        return 1
    end

    set chain_id $argv[1]
    set repo_root (git rev-parse --show-toplevel 2>/dev/null)
    if test $status -ne 0
        echo "Error: Could not determine repository root. Run inside the repo or ensure git is installed." >&2
        return 1
    end

    set broadcast_file "$repo_root/broadcast/DeployAll.s.sol/$chain_id/run-latest.json"

    if not test -f $broadcast_file
        echo "Error: Broadcast file not found at $broadcast_file" >&2
        return 1
    end

    set -l mapping \
        CORE_ADDRESS Core \
        POSITIONS_ADDRESS Positions \
        ORACLE_ADDRESS Oracle \
        TWAMM_ADDRESS TWAMM \
        MEV_CAPTURE_ADDRESS MEVCapture \
        ORDERS_ADDRESS Orders \
        INCENTIVES_ADDRESS Incentives \
        TOKEN_WRAPPER_FACTORY_ADDRESS TokenWrapperFactory

    for idx in (seq 1 2 (count $mapping))
        set var_name $mapping[$idx]
        set contract_name $mapping[(math "$idx + 1")]

        set value (__ekt_lookup_address $contract_name $broadcast_file)
        if test $status -ne 0 -o -z "$value"
            echo "Error: Address for contract $contract_name not found in $broadcast_file" >&2
            return 1
        end

        set -gx $var_name $value
        printf "%s=%s\n" $var_name $value
    end
end

__ekt_main $argv
set -l __ekt_status $status
functions -e __ekt_lookup_address
functions -e __ekt_usage
functions -e __ekt_main
test $__ekt_status -eq 0
