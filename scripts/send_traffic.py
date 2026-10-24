"""Send synthetic customers to the API, optionally with drifted traffic.

python scripts/send_traffic.py --n 1000 --drift 0.8
"""

import argparse
import json
import urllib.request

from churn import data
from churn.config import FEATURES


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://localhost:8000")
    parser.add_argument("--n", type=int, default=500)
    parser.add_argument("--drift", type=float, default=0.0)
    parser.add_argument("--batch", type=int, default=50)
    args = parser.parse_args()

    rows = data.generate(n=args.n, seed=123, drift=args.drift)[FEATURES].to_dict("records")
    churners = 0
    for i in range(0, len(rows), args.batch):
        body = json.dumps({"customers": rows[i : i + args.batch]}).encode()
        req = urllib.request.Request(  # noqa: S310 - URL comes from the CLI
            f"{args.url}/predict", data=body, headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=10) as resp:  # noqa: S310 - local URL
            churners += sum(p["will_churn"] for p in json.load(resp)["predictions"])
    print(f"sent {len(rows)} customers (drift={args.drift}), predicted churners: {churners}")


if __name__ == "__main__":
    main()
