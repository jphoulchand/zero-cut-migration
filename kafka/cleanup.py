#!/usr/bin/env python3
"""
Kafka Auto-Cleanup Script
Deletes Kafka and KRaftController CRDs if current date > cleanup date from secret
"""
import os
from datetime import datetime
from kubernetes import client, config

NAMESPACE = "confluent"
SECRET_NAME = "kafka-cleanup-config"
KAFKA_NAME = "kafka"
KRAFTCONTROLLER_NAME = "kraftcontroller"


def read_secret():
    """Read cleanup configuration from Kubernetes secret"""
    v1 = client.CoreV1Api()

    try:
        secret = v1.read_namespaced_secret(SECRET_NAME, NAMESPACE)
        cleanup_date_str = secret.data.get("cleanup-date")
        dry_run_str = secret.data.get("dry-run")

        if not cleanup_date_str:
            raise ValueError("cleanup-date not found in secret")

        # Decode base64
        import base64
        cleanup_date = base64.b64decode(cleanup_date_str).decode("utf-8").strip()
        dry_run = base64.b64decode(dry_run_str).decode("utf-8").strip().lower() == "true" if dry_run_str else False

        return cleanup_date, dry_run
    except Exception as e:
        print(f"❌ Failed to read secret {SECRET_NAME}: {e}")
        raise


def parse_date(date_str):
    """Parse YYYY-MM-DD date string"""
    try:
        return datetime.strptime(date_str, "%Y-%m-%d").date()
    except ValueError as e:
        print(f"❌ Invalid date format '{date_str}'. Expected YYYY-MM-DD")
        raise


def delete_custom_resource(api, group, version, plural, name, dry_run=False):
    """Delete a custom resource"""
    try:
        if dry_run:
            print(f"[DRY RUN] Would delete {plural}/{name}")
            return True

        api.delete_namespaced_custom_object(
            group=group,
            version=version,
            namespace=NAMESPACE,
            plural=plural,
            name=name
        )
        print(f"✅ Deleted {plural}/{name}")
        return True
    except client.exceptions.ApiException as e:
        if e.status == 404:
            print(f"ℹ️  {plural}/{name} not found (already deleted)")
            return True
        else:
            print(f"❌ Failed to delete {plural}/{name}: {e}")
            return False


def main():
    # Load in-cluster config
    try:
        config.load_incluster_config()
        print("✓ Loaded in-cluster Kubernetes config")
    except Exception:
        # Fallback to local kubeconfig for testing
        config.load_kube_config()
        print("✓ Loaded local kubeconfig")

    # Read cleanup configuration from secret
    cleanup_date_str, dry_run = read_secret()
    print(f"✓ Read secret: cleanup-date={cleanup_date_str}, dry-run={dry_run}")

    # Parse dates
    cleanup_date = parse_date(cleanup_date_str)
    current_date = datetime.now().date()

    print(f"\n{'='*60}")
    print(f"Current date:  {current_date}")
    print(f"Cleanup date:  {cleanup_date}")
    print(f"Dry run:       {dry_run}")
    print(f"{'='*60}\n")

    # Check if cleanup should happen
    if current_date < cleanup_date:
        days_remaining = (cleanup_date - current_date).days
        print(f"⏳ Cleanup date not reached yet. {days_remaining} day(s) remaining.")
        print("✓ No action taken")
        return

    # Cleanup date reached or passed
    days_overdue = (current_date - cleanup_date).days
    if days_overdue > 0:
        print(f"⚠️  Cleanup date OVERDUE by {days_overdue} day(s)!")
    else:
        print(f"⚠️  Cleanup date reached TODAY!")

    print(f"\n{'='*60}")
    print("DELETING KAFKA RESOURCES")
    print(f"{'='*60}\n")

    # Initialize custom objects API
    api = client.CustomObjectsApi()

    # Delete Kafka CR
    kafka_deleted = delete_custom_resource(
        api=api,
        group="platform.confluent.io",
        version="v1beta1",
        plural="kafkas",
        name=KAFKA_NAME,
        dry_run=dry_run
    )

    # Delete KRaftController CR
    kraft_deleted = delete_custom_resource(
        api=api,
        group="platform.confluent.io",
        version="v1beta1",
        plural="kraftcontrollers",
        name=KRAFTCONTROLLER_NAME,
        dry_run=dry_run
    )

    # Summary
    print(f"\n{'='*60}")
    if dry_run:
        print("✓ DRY RUN COMPLETE - No resources deleted")
    else:
        if kafka_deleted and kraft_deleted:
            print("✓ CLEANUP COMPLETE")
            print(f"  → Estimated monthly savings: $184")
        else:
            print("⚠️  CLEANUP INCOMPLETE - Some deletions failed")
    print(f"{'='*60}\n")


if __name__ == "__main__":
    main()
