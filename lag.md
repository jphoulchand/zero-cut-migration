# Kafka Producer-to-Broker Lag Measurement

This directory contains two scripts for measuring the latency between when a message is produced and when it's appended to the Kafka broker log.

## Scripts Overview

### 1. perf-producer.py

Performance test producer that adds timestamp headers to enable lag measurement.

**Purpose:**
- Alternative to `kafka-producer-perf-test` with custom header support
- Adds `produce_time` header to each message (timestamp in milliseconds)
- Pre-generates 100MB of random data for realistic compression testing
- Supports throughput control, compression, and batching configuration

**Key Features:**
- Adds `produce_time` header automatically with millisecond precision
- Pre-generates 100MB random data pool and rotates through it for each message
- Supports compression types: none, gzip, snappy, lz4, zstd
- Configurable throughput limiting
- Real-time statistics reporting
- Compatible with standard Kafka producer settings (batch.size, linger.ms, acks)

**Usage:**
```bash
python3 perf-producer.py \
  --topic demo-isr-2 \
  --num-records 100000 \
  --record-size 1024 \
  --compression-type lz4 \
  --batch-size 32768 \
  --linger-ms 10
```

### 2. lag.py

Consumer-based lag analyzer that measures producer→broker latency.

**Purpose:**
- Consumes messages and calculates the time difference between:
  - When the producer created the message (`produce_time` header)
  - When the broker appended it to the log (LogAppendTime)
- Provides min/max/average latency statistics

**Key Features:**
- Validates topic is configured with LogAppendTime
- Shows sample message details for debugging
- Tracks messages read vs messages with valid lag data
- Auto-stops after 10 seconds of no new messages
- Provides clear diagnostics when lag cannot be calculated

**Usage:**
```bash
python3 lag.py
```

**Output:**
```
--- Latency Report (Producer -> Log Append) ---
Total Messages Analyzed: 98543
Minimum Lag:             2 ms
Maximum Lag:             145 ms
Average Lag:             12.45 ms
-----------------------------------------------
```

## Prerequisites

### Topic Configuration

The topic **must** be configured with `LogAppendTime`:

```bash
kafka-configs --alter \
  --bootstrap-server kafka.confluent.svc.cluster.local:9092 \
  --topic demo-isr-2 \
  --add-config message.timestamp.type=LogAppendTime
```

Verify configuration:
```bash
kafka-configs \
  --bootstrap-server kafka.confluent.svc.cluster.local:9092 \
  --describe \
  --topic demo-isr-2 \
  --all | grep message.timestamp.type
```

### Python Dependencies

```bash
pip install confluent-kafka
```

## Workflow

1. **Configure topic** with LogAppendTime (see above)

2. **Produce test messages** with headers:
   ```bash
   python3 perf-producer.py \
     --topic demo-isr-2 \
     --num-records 100000 \
     --record-size 1024 \
     --compression-type lz4
   ```

3. **Measure lag**:
   ```bash
   python3 lag.py
   ```

4. **Analyze results** to understand producer→broker latency

## What This Measures

**Producer → Broker Lag** is the time between:
- **Start:** When `producer.produce()` is called and the message gets a timestamp
- **End:** When the broker appends the message to the partition log

This lag includes:
- Network transmission time
- Producer-side batching delays (`linger.ms`)
- Broker-side processing time
- Replication time (if `acks=all`)

**This does NOT measure:**
- Consumer lag (how far behind consumers are)
- End-to-end latency (producer → consumer)
- Time spent in producer buffer before sending

## Troubleshooting

### "No valid messages with 'produce_time' headers were found"
- Use `perf-producer.py` instead of `kafka-producer-perf-test`
- Standard Kafka tools don't support custom headers

### "Topic uses CreateTime, not LogAppendTime"
- Reconfigure topic with LogAppendTime (see Prerequisites)
- Without LogAppendTime, broker append timestamp is not available

### "No messages received for 10 seconds"
- Topic may be empty
- Check topic has data: `kafka-console-consumer --topic demo-isr-2 --max-messages 1`
- Adjust `auto.offset.reset` in lag.py if needed

## Performance Tuning

Test different producer configurations to see their impact on lag:

```bash
# Baseline - no batching
python3 perf-producer.py --topic demo-isr-2 --num-records 10000 --linger-ms 0

# With batching
python3 perf-producer.py --topic demo-isr-2 --num-records 10000 --linger-ms 10

# With compression
python3 perf-producer.py --topic demo-isr-2 --num-records 10000 --compression-type lz4

# All optimizations
python3 perf-producer.py --topic demo-isr-2 --num-records 10000 \
  --linger-ms 10 --batch-size 32768 --compression-type lz4
```

Then run `lag.py` after each test to compare latency impact.
