# Internal Apollo fork of kafka-assigner

We occasionally use this old unmaintained tool to move partitions around between brokers. (We may want to look into [Kafka Cruise Control](https://github.com/linkedin/cruise-control) or [Google Cloud Managed Service For Kafka](https://cloud.google.com/products/managed-service-for-apache-kafka?hl=en) as an alternative in the future.) This fork makes it easier for us to run it and adds some shell scripts that we use.

This is branched off [an old unmerged PR](https://github.com/SiftScience/kafka-assigner/pull/6) that fixed a bug we ran into.

To build it, set up [Mise](https://apollographql.atlassian.net/wiki/spaces/Foundation/pages/1490583600/Mise+standardized+dev+tools+made+simple) and run `mise run build`. You now will be able to run the upstream shell script `kafka-assignment-generator.sh` as well as our scripts `kafka-plan-reassignments.sh` and `kafka-execute-reassignments.sh`.

To adjust the version of Kafka used by our shell scripts, see `.config/mise/config.toml`.


## Moving Partitions

To move partitions to or from brokers in the cluster:

1. Enable [VPN direct network access](https://apollographql.atlassian.net/wiki/spaces/SecOps/pages/635928580/Accessing+Private+Resources+in+Kubernetes#Direct-Network-Access) (including [requesting permission](https://go.gql.zone/moreaccess)).

1. List all topics and their retentions so you can put things back the way they were if need be:

```
kafka-topics --bootstrap-server bootstrap.kafka-default.svc.$STACK.apollo-internal:9092 --describe | grep Configs | sed -E 's/^Topic: ([a-z0-9_-]+).*ReplicationFactor: ([0-9]+).*retention.ms=([0-9]+).*$/| \1 | \2 | \3 |/'
```

1. Decide if you need to drop retention on topics by inspecting the throughput metrics in the [Kafka Health dashboard](https://app.datadoghq.com/dashboard/w4d-6jd-rtu/kafka-health). High throughput topics == more data to move across the network and slower repartitioning.

   Dropping retention temporarily is relatively safe - the long retention periods are intended to give us time to perform recovery efforts during an incident. As long as the consumer lag for a topic stays low, there is no impact to the lower retention rate.

   During previous resizing efforts, we've dropped retention for the following topics:

   - `engine-traces`: 3 hours
   - `engine-reports-stats`: 3 hours
   - `engine-reports-trace-processed`: 3 hours
   - `billing-usage-stats`: 6 hours (longer because it's billing and we don't want to risk losing this data)

   Drop retention on the topics in question to 3 (`10800000` ms) or 6 hours (`21600000` ms): [See steps above](#setting-retention-aka-drop-disk-usage-fast)

   **Remember to reset the retention after you're done moving partitions!** You can also consider resetting the retention to its original value after Kafka has finished removing the old data.
   After retention is reset, be wary of any "usage over time" monitoring: it could appear that usage is increasing much more rapidly than before the move, because Kafka is no longer deleting expired data, only adding.
   The usage increase will stabilize when you reach the new retention time limit.

1. Set up your environment, select the broker you want to decommission (if applicable), and generate a plan to move topics:

   ```shell
   export STACK=dev   # or staging or prod, but not dev0
   export BROKER_ID_TO_REMOVE=4 # can specify multiple brokers separated by commas - e.g. 4,5,6
   export TOPIC=all # can also provide specific topics instead of planning assignments for all

   kafka-plan-reassignments.sh -s $STACK -b $BROKER_ID_TO_REMOVE -t $TOPIC
   ```

   If you are adding a broker, you can leave off the `-b $BROKER_ID_TO_REMOVE` section. This command can also be used to rebalance partitions if they have become unbalanced.

   This step will generate a lot of files inside a temporary directory (`kafka-move-$BROKER_ID_TO_REMOVE-$STACK`) so that partitions can be moved individually.

1. After generating plans, you can begin executing the reassignments:

   ```shell
   kafka-execute-reassignments.sh -s $STACK -b $BROKER_ID_TO_REMOVE
   ```

   This step will begin executing the reassignments one-by-one and wait for their success before moving to the next one. You'll be prompted before each reassignment begins.

   As reassignments complete, the plan files are renamed to have a `*.completed` ending. This preserves the execution history in case you need to rollback.

   This also means you can safely exit the script and resume work later, without repeating completed work.

   Tip: Use `yes | kafka-execute-reassignments.sh ...` to automate the approval process, after you feel confident with the steps. Continue monitoring while the script runs.

1. Monitor the impact of reassignments using the [Kafka Repartitioning dashboard](https://app.datadoghq.com/dashboard/6g3-gz3-kmq). This dashboard shows data about consumer lag, network throughput, and progress.

1. If you need to cancel an active partition reassignment due to performance concerns, Ctrl-C to exit the execution script and re-run it. The script should select the last-attempted assignment file. Enter cancel at the prompt.

1. Repeat the above until all topics have been moved. If you are removing a broker you can use the Kafka Manager UI to check for partitions: example, [staging broker 100](https://kafka-manager-staging.access.apollographql.com/clusters/Staging/brokers/100).

   - Note: Due to a bug in the UI, the final partition removed continues displaying on the broker details page. You can restart kafka-manager to refresh this list to doublecheck that it's truly been removed.

1. If you are removing a broker: you can now safely shut down the broker for permanent removal or disk replacement.
