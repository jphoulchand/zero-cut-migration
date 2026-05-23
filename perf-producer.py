#!/usr/bin/env python3
"""
Kafka performance test producer with produce_time header support.
Alternative to kafka-producer-perf-test that adds timestamp headers for lag measurement.
"""

from confluent_kafka import Producer
import time
import random
import string
import argparse
import sys

def generate_payload(size):
    """Generate random payload of specified size in bytes."""
    return ''.join(random.choices(string.ascii_letters + string.digits, k=size))

def delivery_callback(err, msg):
    """Callback for message delivery reports."""
    if err:
        sys.stderr.write(f'Message delivery failed: {err}\n')

def run_perf_test(args):
    """Run the performance test."""

    # Configure producer
    conf = {
        'bootstrap.servers': args.bootstrap_server,
        'linger.ms': args.linger_ms,
        'batch.size': args.batch_size,
        'compression.type': args.compression_type,
        'acks': args.acks,
    }

    producer = Producer(conf)

    # Pre-generate 100MB of random data for realistic compression testing
    print("Pre-generating 100MB of random data for realistic compression...")
    data_pool_size = 100 * 1024 * 1024  # 100MB
    data_pool = generate_payload(data_pool_size)
    print(f"Generated {len(data_pool) / 1024 / 1024:.1f} MB of random data\n")

    # Calculate timing
    messages_sent = 0
    start_time = time.time()
    next_report = start_time + args.print_interval

    # Throughput control
    if args.throughput > 0:
        sleep_time = 1.0 / args.throughput
    else:
        sleep_time = 0

    print(f"Starting performance test:")
    print(f"  Topic: {args.topic}")
    print(f"  Messages: {args.num_records}")
    print(f"  Record size: {args.record_size} bytes")
    print(f"  Target throughput: {'unlimited' if args.throughput <= 0 else f'{args.throughput} msg/sec'}")
    print(f"  Compression: {args.compression_type}")
    print(f"  Batch size: {args.batch_size}")
    print(f"  Linger: {args.linger_ms} ms")
    print(f"  Acks: {args.acks}")
    print()

    try:
        for i in range(args.num_records):
            # Add produce_time header with current timestamp in milliseconds
            produce_time = int(time.time() * 1000)
            headers = {'produce_time': str(produce_time)}

            # Get payload slice from the pre-generated data pool
            # Rotate through the pool to ensure different data for each message
            start_offset = (i * args.record_size) % (data_pool_size - args.record_size)
            payload = data_pool[start_offset:start_offset + args.record_size]

            # Produce message
            producer.produce(
                args.topic,
                value=payload.encode('utf-8'),
                headers=headers,
                callback=delivery_callback
            )

            messages_sent += 1

            # Poll to handle delivery callbacks
            producer.poll(0)

            # Throughput control
            if sleep_time > 0:
                time.sleep(sleep_time)

            # Periodic status report
            current_time = time.time()
            if current_time >= next_report:
                elapsed = current_time - start_time
                rate = messages_sent / elapsed
                print(f"Sent {messages_sent} messages | {rate:.2f} msg/sec | {elapsed:.1f} sec elapsed")
                next_report = current_time + args.print_interval

    except KeyboardInterrupt:
        print("\nInterrupted by user")

    finally:
        # Flush remaining messages
        print(f"\nFlushing {len(producer)} remaining messages...")
        producer.flush(30)

        # Final statistics
        end_time = time.time()
        total_time = end_time - start_time

        print("\n" + "="*70)
        print("Performance Test Results")
        print("="*70)
        print(f"Total messages sent:    {messages_sent:,}")
        print(f"Total time:             {total_time:.2f} seconds")
        print(f"Average throughput:     {messages_sent / total_time:.2f} msg/sec")
        print(f"Total data sent:        {messages_sent * args.record_size / 1024 / 1024:.2f} MB")
        print(f"Average MB/sec:         {messages_sent * args.record_size / 1024 / 1024 / total_time:.2f} MB/sec")
        print("="*70)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(
        description='Kafka performance test producer with produce_time header',
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )

    # Required arguments
    parser.add_argument('--topic', required=True,
                        help='Topic to produce to')
    parser.add_argument('--num-records', type=int, required=True,
                        help='Number of messages to produce')

    # Connection settings
    parser.add_argument('--bootstrap-server', default='kafka.confluent.svc.cluster.local:9092',
                        help='Kafka bootstrap server')

    # Message settings
    parser.add_argument('--record-size', type=int, default=1024,
                        help='Message size in bytes')

    # Performance settings
    parser.add_argument('--throughput', type=int, default=-1,
                        help='Target throughput in msg/sec (-1 for unlimited)')
    parser.add_argument('--batch-size', type=int, default=16384,
                        help='Batch size in bytes')
    parser.add_argument('--linger-ms', type=int, default=0,
                        help='Linger time in milliseconds')
    parser.add_argument('--compression-type', default='none',
                        choices=['none', 'gzip', 'snappy', 'lz4', 'zstd'],
                        help='Compression type')
    parser.add_argument('--acks', default='all',
                        choices=['0', '1', 'all'],
                        help='Acks configuration')

    # Reporting
    parser.add_argument('--print-interval', type=int, default=5,
                        help='Print stats every N seconds')

    args = parser.parse_args()
    run_perf_test(args)
