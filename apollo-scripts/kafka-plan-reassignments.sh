#!/usr/bin/env bash
set -eu

## Generate reassignment plans on a per-partition basis in order to decommission Kafka brokers or rebalance leadership
## This script outputs results to a folder, which can be reviewed and later invoked by kafka-execute-reassignments.
## Examples:

## > kafka-plan-reassignments.sh -s staging -b 4
## Plans full decommissioning of broker ID 4 from staging

## > kafka-plan-reassignments.sh -s staging -t billing-usage-stats
## Plans rebalance of the billing-usage-stats topic
## The assignment generator attempts to minimize movement, so this will only return results if there is skew

usage() { echo "Usage: $0 [-s <dev|staging|prod>] [-b <broker id to remove (optional)>] [-t <topics to move|all>]" 1>&2; exit 1; }

while getopts ":s:b:t:" o; do
    case "${o}" in
        s)
            STACK=${OPTARG}
            ;;
        b)
            BROKER_ID=${OPTARG}
            ;;
        t)
            TOPICS_TO_MOVE=${OPTARG}
            ;;
        *)
            usage
            ;;
    esac
done

REASSIGN_ARGS=""

if [[ ! -z ${BROKER_ID:-} ]]; then
    for ID in ${BROKER_ID//,/ }; do
      BROKER_TO_MOVE+=kafka-$ID.kafka.kafka-default.svc.$STACK.apollo-internal,
    done
    echo "Planning to remove $BROKER_TO_MOVE"
    REASSIGN_ARGS+="--broker_hosts_to_remove $BROKER_TO_MOVE"
fi

if [[ "${TOPICS_TO_MOVE:-all}" == "all" ]]; then
    TOPICS_TO_MOVE=`kafka-topics --zookeeper zk-0.apollo-default.svc.$STACK.apollo-internal --list`
fi

function gen_diff () {
   TOPIC_TO_MOVE=$1
   echo "Diff for: $TOPIC_TO_MOVE"
   kafka-assignment-generator.sh --zk_string zk-0.apollo-default.svc.$STACK.apollo-internal $REASSIGN_ARGS --mode PRINT_REASSIGNMENT --topics $TOPIC_TO_MOVE > dump--assignments.json
   sed -n 2p dump--assignments.json > current-$TOPIC_TO_MOVE-unsorted.json
   sed -n 4p dump--assignments.json > new-$TOPIC_TO_MOVE-unsorted.json
   for f in current-$TOPIC_TO_MOVE new-$TOPIC_TO_MOVE; do jq -S <$f-unsorted.json '.partitions |= sort_by(.topic, .partition)' >$f.json; done
   count=$(diff current-$TOPIC_TO_MOVE.json new-$TOPIC_TO_MOVE.json | grep ">" | wc -l | tr -d ' ')
   if [[ "$count" != "0" ]]; then
       echo "Partition reassignment count: $count"
       gen_detailed_plans $TOPIC_TO_MOVE
   else
       echo "No reassignment needed"
   fi
}

# Break out the results so each plan contains a single partition movement
# This allows us to move data very slowly
function gen_detailed_plans() {
    TOPIC=$1
    PARTITION_COUNT=`cat new-$TOPIC.json | jq '.partitions | length'`
    for i in $(seq 0 $PARTITION_COUNT); do
        new_partition=$(cat new-$TOPIC.json | jq ".partitions |= .[$i:$i+1]")
        curr_partition=$(cat current-$TOPIC.json | jq ".partitions |= .[$i:$i+1]")
        # Only generate plans if the partitions are going to move
        if [[ "$new_partition" != "$curr_partition" ]]; then
            echo $new_partition > reassign-$TOPIC-$i.json
        fi
    done
}

WORKDIR=kafka-move-${BROKER_ID:-}-$STACK
mkdir -p $WORKDIR

cd $WORKDIR
for TOPIC in $TOPICS_TO_MOVE; do
   gen_diff $TOPIC
done
