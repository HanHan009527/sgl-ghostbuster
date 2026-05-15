import os
import socket

from mooncake.engine import TransferEngine


devices = os.environ["RDMA_EXPECTED_DEVICES"]
hostname = socket.gethostbyname(socket.gethostname())
engine = TransferEngine()
ret = engine.initialize(hostname, "P2PHANDSHAKE", "rdma", devices)
print(
    "Mooncake TransferEngine.initialize ret=",
    ret,
    "hostname=",
    hostname,
    "devices=",
    devices,
)
if ret != 0:
    raise SystemExit(ret)
