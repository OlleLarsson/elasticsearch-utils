#!/bin/bash

# This script is meant to be used for reindexing time-based indices controlled
# by elasticsearches' ILM feature. The indices should should already have
# completed the rollover step, as this script assumes that the indices are no
# longer being actively written to.

# Note: The new indices will not be under control of ILM as the policy will be
#       removed from the new indices as to avoid rollovers from occurring.

# The script will:
#  For each passed index 'x'
#    Create new index 'x-reindexed'
#    Remove ilm policy from 'x-reindexed'
#    Tune 'x-reindexed's settings
#    Reindex
#    Force merge 'x-reindexed' to 1 segment
#    Revert 'x-reindexed's settings

# Note: The script will not delete the original indices.

# Future improvements:
# - Improved error handling and logging
# - Reindex all indices before enabling replication
# - Tune cluster parameters for replication
#   - cluster.routing.allocation.node_concurrent_recoveries
#   - indices.recovery.max_bytes_per_sec
#   I avoided these as the capacity might vary depending on compute resources available.

# Elasticsearch variables.
: "${ES_USER:? Missing ES_USER}"
: "${ES_PASSWORD:? Missing ES_PASSWORD}"
: "${ES_HOST:? Missing ES_HOST}"

readonly suffix="reindexed"
original_index_settings=null

function log () {
    echo "$(date "+%Y-%m-%d %H:%M:%S.%3N") - ${@}"
}

[ "${#}" -lt 1 ] && echo "Usage ${0} <indices_to_reindex>" && exit 1

log "I was called as: $0 $@"

function get_default_index_settings () {
    original_index_settings=$(curl -ks -X GET "${ES_HOST}/${1}/_settings" \
        -u "${ES_USER}:${ES_PASSWORD}")
}

function create_new_index () {
    log "Creating index [${1}}]"
    curl -ks -X PUT "${ES_HOST}/${1}?pretty" \
        -u "${ES_USER}:${ES_PASSWORD}" \
        | tee /dev/stderr | grep "resource_already_exists_exception" >/dev/null 2>&1 && return 1
    return 0
}

function tune_index_settings () {
    log "Tune settings for index [${1}]"
    curl -ks -X PUT "${ES_HOST}/${1}/_settings?pretty" \
        -u "${ES_USER}:${ES_PASSWORD}" \
        -H 'Content-Type: application/json' -d'
        {
            "index" : {
                "number_of_replicas" : 0,
                "refresh_interval" : "-1",
                "translog.durability" : "async"
            }
        }
        '
}

function restore_index_settings () {
    log "Restoring settings for index [${1}]"

    # We don't care if 'null' as it will restore default value.
    # https://www.elastic.co/guide/en/elasticsearch/reference/current/indices-update-settings.html#reset-index-setting
    number_of_replicas=$(echo "${original_index_settings}" | jq '."'"${1}"'".settings.index."number_of_replicas"')
    refresh_interval=$(echo "${original_index_settings}" | jq '."'"${1}"'".settings.index."refresh_interval"')
    translog_durability=$(echo "${original_index_settings}" | jq '."'"${1}"'".settings.index.translog.durability')

    curl -ks -X PUT "${ES_HOST}/${1}/_settings?pretty" \
        -u "${ES_USER}:${ES_PASSWORD}" \
        -H 'Content-Type: application/json' -d'
        {
            "index" : {
                "number_of_replicas" : '"${number_of_replicas}"',
                "refresh_interval" : '"${refresh_interval}"',
                "translog.durability" : '"${translog_durability}"'
            }
        }
        '
}

function force_merge () {
    log "Force merging index [${1}]"

    curl -ks -X POST "${ES_HOST}/${1}/_forcemerge?max_num_segments=1&pretty" \
        -u "${ES_USER}:${ES_PASSWORD}"
}

function remove_ilm_policy () {
    log "Removing ilm policy from [${1}]"
    curl -ks -X POST "${ES_HOST}/${1}/_ilm/remove?pretty" \
        -u "${ES_USER}:${ES_PASSWORD}"
}

function reindex () {
    src_index="${1}"
    dst_index="${2}"

    # Reindex data to new index.
    log "Starting to reindex \"${src_index}\" to \"${dst_index}\""
    task=$(curl -ks -X POST "${ES_HOST}/_reindex?wait_for_completion=false&pretty" -H 'Content-Type: application/json' -u "${ES_USER}:${ES_PASSWORD}" -d'
    {
        "source": {
            "index": "'"${src_index}"'"
        },
        "dest": {
            "index": "'"${dst_index}"'"
        }
    }
    ' | tee /dev/stderr | jq -r '.task')

    log "Task ID: ${task}"

    while true; do
        status=$(curl -ks -X GET "${ES_HOST}/_tasks/${task}" -u "${ES_USER}:${ES_PASSWORD}" | jq '.completed')
        [ "${status}" = "true" ] && break;
        docs_total=$(curl -ks -X GET "${ES_HOST}/_tasks/${task}" -u "${ES_USER}:${ES_PASSWORD}" | jq '.task.status.total')
        docs_done=$(curl -ks -X GET "${ES_HOST}/_tasks/${task}" -u "${ES_USER}:${ES_PASSWORD}" | jq '.task.status.created')
        log "Waiting for reindexing to complete - ${docs_done} / ${docs_total} documents done."
        sleep 10
    done

    # Show user result of task
    log "Reindexing complete"
    curl -ks -X GET "${ES_HOST}/_tasks/${task}?pretty" -u "${ES_USER}:${ES_PASSWORD}"

}


for index in "${@}"; do
    log "Starting to handle index [${index}]"
    new_index="${index}-${suffix}"

    if create_new_index "${new_index}"; then
        remove_ilm_policy          "${new_index}"
        get_default_index_settings "${new_index}"
        tune_index_settings        "${new_index}"
        reindex                    "${index}" ${new_index}
        force_merge                "${new_index}"
        restore_index_settings     "${new_index}"
        log "Index [${index}] done"
    fi
done
