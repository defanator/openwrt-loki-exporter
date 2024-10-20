"""
Base tests for loki_exporter
"""

from datetime import datetime, timedelta, timezone
from client import BASE_URL, query_labels, query_range


def test_labels():
    """
    Check available labels and match with expectation
    """
    response = query_labels(BASE_URL)

    assert "status" in response.keys()
    assert response.get("status") == "success"

    assert "data" in response.keys()
    data = response.get("data")
    assert isinstance(data, list)

    assert len(data) == 2, "total count of available labels"

    for label in ("host", "job"):
        assert label in data, f'label "{label}" found'


def test_line_count():
    """
    Verify that loki returns expected number of processed lines
    """
    query = '{job="openwrt_loki_exporter"}'
    current_time = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    start_time = (datetime.now(timezone.utc) - timedelta(hours=2)).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    end_time = current_time

    response = query_range(BASE_URL, query, start_time, end_time, limit=1000)

    assert "status" in response.keys()
    assert response.get("status") == "success"

    assert "data" in response.keys()
    data = response.get("data")
    assert isinstance(data, dict)

    assert "result" in data.keys()
    result = data.get("result")
    assert isinstance(result, list)

    assert "stats" in data.keys()
    stats = data.get("stats")
    assert isinstance(stats, dict)

    assert "summary" in stats.keys()
    assert (
        stats.get("summary", {}).get("totalLinesProcessed") == 491
    ), "count of total processed lines"
