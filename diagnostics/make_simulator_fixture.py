#!/usr/bin/env python3
"""Build a small binary .fogwalk archive for simulator-only visual QA."""

import csv
import datetime as dt
import pathlib
import plistlib


ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "demodata" / "backUpData-all.csv"
OUTPUT = ROOT / "artifacts" / "simulator-today.fogwalk"
CHINA_TIME = dt.timezone(dt.timedelta(hours=8))


with SOURCE.open(newline="", encoding="utf-8") as handle:
    rows = list(csv.DictReader(handle))

latest_timestamp = max(int(row["dataTime"]) for row in rows)
latest_day = dt.datetime.fromtimestamp(latest_timestamp, CHINA_TIME).date()
today_rows = [
    row
    for row in rows
    if dt.datetime.fromtimestamp(int(row["dataTime"]), CHINA_TIME).date() == latest_day
]


def plist_date(timestamp: int) -> dt.datetime:
    return dt.datetime.fromtimestamp(timestamp, dt.timezone.utc).replace(tzinfo=None)


points = []
for index, row in enumerate(today_rows, start=1):
    points.append(
        {
            "id": index,
            "timestamp": plist_date(int(row["dataTime"])),
            "coordinate": {
                "latitude": float(row["latitude"]),
                "longitude": float(row["longitude"]),
            },
            "horizontalAccuracy": float(row["accuracy"]),
            "speed": float(row["speed"]),
            "altitude": float(row["altitude"]),
            "source": "recordedCSV",
        }
    )

archive = {
    "version": 1,
    "exportedAt": dt.datetime.now(dt.timezone.utc).replace(tzinfo=None),
    "dataset": {
        "points": points,
        "summary": {
            "recordedCSVCount": len(points),
            "photoCSVCount": 0,
            "gpxCount": 0,
            "duplicateCount": 0,
            "uniqueCount": len(points),
            "earliestDate": points[0]["timestamp"],
            "latestDate": points[-1]["timestamp"],
        },
    },
}

with OUTPUT.open("wb") as handle:
    plistlib.dump(archive, handle, fmt=plistlib.FMT_BINARY)

print(f"wrote {OUTPUT} with {len(points)} points")
