import pathlib

import mooncake


print("Mooncake package:", mooncake.__file__)
bench = pathlib.Path(mooncake.__path__[0]) / "transfer_engine_bench"
print("Mooncake transfer_engine_bench:", bench, "exists=", bench.exists())
if not bench.exists():
    raise SystemExit("transfer_engine_bench is missing")
