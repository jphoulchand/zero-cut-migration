from confluent_kafka import Consumer, KafkaError
import sys

def calculate_lag():
    # 1. Configure the Consumer
    conf = {
        'bootstrap.servers': 'kafka.confluent.svc.cluster.local:9092',
        'group.id': 'lag-analyzer-group',
        'auto.offset.reset': 'earliest' # Start from beginning to analyze historical lag
    }

    consumer = Consumer(conf)
    topic = 'demo-isr-2'
    consumer.subscribe([topic])

    lags_ms = []
    messages_processed = 0
    messages_read = 0
    max_messages_to_analyze = 100000 # Stop after analyzing this many messages
    show_sample = True
    no_message_timeout = 0
    max_no_message_timeout = 10  # Exit after 10 seconds of no messages

    print(f"Listening to '{topic}' to calculate produce vs. log append lag...")
    print("Reading messages... (Ctrl+C to stop and calculate)\n")

    try:
        while messages_processed < max_messages_to_analyze:
            msg = consumer.poll(timeout=1.0)

            if msg is None:
                no_message_timeout += 1
                if no_message_timeout >= max_no_message_timeout:
                    print(f"\nNo messages received for {max_no_message_timeout} seconds. Stopping...")
                    break
                continue

            no_message_timeout = 0  # Reset timeout counter

            if msg.error():
                if msg.error().code() == KafkaError._PARTITION_EOF:
                    print(f"Reached end of partition {msg.partition()}")
                    continue
                else:
                    print(f"Consumer error: {msg.error()}")
                    break

            messages_read += 1

            # 2. Extract timestamps
            ts_type, timestamp = msg.timestamp()

            # Show sample message details for first message
            if show_sample:
                print(f"--- Sample Message (Partition {msg.partition()}, Offset {msg.offset()}) ---")
                timestamp_types = {
                    0: "CreateTime (producer timestamp)",
                    1: "LogAppendTime (broker timestamp - old API)",
                    2: "LogAppendTime (broker timestamp)"
                }
                print(f"Timestamp type: {ts_type} - {timestamp_types.get(ts_type, 'Unknown')}")
                print(f"Timestamp: {timestamp} ms")

                headers = msg.headers()
                if headers:
                    print(f"Headers:")
                    for key, value in headers:
                        print(f"  {key}: {value}")
                else:
                    print("Headers: None")
                print("--------------------------------------------------------------\n")
                show_sample = False

            # 3. Extract produce time and log append time
            produce_time = None
            log_append_time = None

            # Get produce time from header if present
            headers = msg.headers()
            if headers:
                for key, value in headers:
                    if key == 'produce_time':
                        produce_time = int(value.decode('utf-8'))
                        break

            # Determine produce_time and log_append_time based on timestamp type
            if ts_type == 2:
                # LogAppendTime - timestamp is when broker appended
                log_append_time = timestamp
                # If no produce_time header, we can't calculate lag
                if not produce_time:
                    if messages_read == 1:
                        print(f"INFO: Topic has LogAppendTime configured (good!)")
                        print(f"INFO: But messages don't have 'produce_time' header")
                        print(f"INFO: You need to add this header when producing messages\n")
                    continue
            elif ts_type == 0:
                # CreateTime - timestamp is when producer created
                print("\n" + "="*70)
                print("ERROR: Topic is configured with CreateTime, not LogAppendTime")
                print("="*70)
                print("\nTo calculate broker lag, the topic must use LogAppendTime.")
                print("\nFix this by updating the topic configuration:")
                print("  kafka-configs --alter --topic demo-isr-2 \\")
                print("    --add-config message.timestamp.type=LogAppendTime\n")
                print("Or set it as default for new topics in broker config:")
                print("  log.message.timestamp.type=LogAppendTime")
                print("="*70 + "\n")
                break
            else:
                # Unknown timestamp type
                if messages_read == 1:
                    print(f"WARNING: Unknown timestamp type: {ts_type}")
                continue

            # 4. Compute Lag
            if produce_time and log_append_time:
                lag = log_append_time - produce_time
                lags_ms.append(lag)
                messages_processed += 1

                if messages_processed % 1000 == 0:
                    print(f"Processed {messages_processed} messages with valid lag data... (Read {messages_read} total)")

    except KeyboardInterrupt:
        print("\nProcess interrupted by user. Calculating current metrics...")
    finally:
        consumer.close()

    # 5. Output Statistics
    print(f"\nTotal messages read: {messages_read}")
    print(f"Messages with valid lag data: {messages_processed}")

    if not lags_ms:
        print("\nNo valid lag measurements found.")
        print("Possible reasons:")
        print("  1. Messages don't have 'produce_time' header")
        print("  2. Topic not configured with LogAppendTime")
        print("  3. No messages in topic")
        return

    min_lag = min(lags_ms)
    max_lag = max(lags_ms)
    avg_lag = sum(lags_ms) / len(lags_ms)

    print("\n--- Latency Report (Producer -> Log Append) ---")
    print(f"Total Messages Analyzed: {len(lags_ms)}")
    print(f"Minimum Lag:             {min_lag} ms")
    print(f"Maximum Lag:             {max_lag} ms")
    print(f"Average Lag:             {avg_lag:.2f} ms")
    print("-----------------------------------------------")

if __name__ == '__main__':
    calculate_lag()
