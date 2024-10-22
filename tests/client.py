#!/usr/bin/env python3
"""
Helper functions for Loki clients
"""

import json
import requests

BASE_URL = "http://127.0.0.1:3100"


def flush(base_url):
    """
    Flush in-memory chunks to backing store

    https://grafana.com/docs/loki/latest/reference/loki-http-api/#flush-in-memory-chunks-to-backing-store
    """
    headers = {
        "Accept": "application/json",
        "X-Scope-OrgID": "1",
    }

    try:
        response = requests.get(
            f"{base_url}/flush",
            headers=headers,
            timeout=3,
        )
        if response.status_code != 204:
            return False

        return True

    except requests.exceptions.RequestException as exc:
        print(f"ERROR querying {base_url}/flush: {exc}")
        return None


def query_labels(base_url):
    """
    Obtain a list of available labels

    https://grafana.com/docs/loki/latest/reference/loki-http-api/#query-labels
    """
    headers = {
        "Accept": "application/json",
        "X-Scope-OrgID": "1",
    }

    try:
        response = requests.get(
            f"{base_url}/loki/api/v1/labels",
            headers=headers,
            timeout=3,
        )
        if response.status_code != 200:
            return None
        try:
            return response.json()
        except json.JSONDecodeError:
            return None

    except requests.exceptions.RequestException as exc:
        print(f"ERROR querying {base_url}/loki/api/v1/labels: {exc}")
        return None


def query_range(base_url, query, start_time, end_time, limit=100):
    """
    Query logs within a given range

    https://grafana.com/docs/loki/latest/reference/loki-http-api/#query-logs-within-a-range-of-time
    """
    headers = {
        "Accept": "application/json",
        "X-Scope-OrgID": "1",
    }

    payload = {
        "query": query,
        "start": start_time,
        "end": end_time,
        "limit": limit,
    }

    try:
        response = requests.get(
            f"{base_url}/loki/api/v1/query_range",
            params=payload,
            headers=headers,
            timeout=3,
        )
        if response.status_code != 200:
            return None
        try:
            return response.json()
        except json.JSONDecodeError:
            return None

    except requests.exceptions.RequestException as exc:
        print(f"ERROR querying {base_url}/loki/api/v1/query_range: {exc}")
        return None
