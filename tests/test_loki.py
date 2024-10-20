"""
Base tests for loki_exporter
"""

from datetime import datetime, timedelta, timezone
from client import BASE_URL, query_labels, query_range

# from client import flush


def test_labels():
    """
    Check available labels and match with expectation
    """
    # assert flush(BASE_URL) is True, "flush succeeded"

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

    # assert flush(BASE_URL) is True, "flush succeeded"

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
    # assert len(result) == 1

    l = []

    total_entries = 0
    for h in result:
        for k, v in h.items():
            if k == "values":
                total_entries += len(v)
                for entry in v:
                    ts = int(entry[0]) / 10**9
                    msg = entry[1]
                    l.append({"ts": ts, "msg": msg})

    l = sorted(l, key=lambda d: d["ts"])
    with open("tests/resurrected.log", "w", encoding="utf-8") as file:
        for entry in l:
            file.write(f"{entry['ts']:.3f}: {entry['msg']}\n")

    assert total_entries == 491

    assert "stats" in data.keys()
    stats = data.get("stats")
    assert isinstance(stats, dict)

    assert "summary" in stats.keys()
    assert (
        stats.get("summary", {}).get("totalLinesProcessed") == 491
    ), "count of total processed lines"
