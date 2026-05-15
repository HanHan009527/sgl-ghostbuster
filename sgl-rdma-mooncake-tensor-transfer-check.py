import multiprocessing as mp
import os
import queue
import socket
import sys
import time
import traceback


def _fail(message):
    print(f"Mooncake tensor transfer check failed: {message}", flush=True)
    raise SystemExit(1)


def _check_ret(name, ret):
    if ret != 0:
        raise RuntimeError(f"{name} returned {ret}")


def _local_ip():
    return socket.gethostbyname(socket.gethostname())


def _make_pattern(torch, nbytes, device):
    return torch.arange(nbytes, dtype=torch.uint8, device=device)


def _target_worker(devices, cuda_device, nbytes, ready_q, command_q, result_q):
    try:
        import torch
        from mooncake.engine import TransferEngine

        device = torch.device(f"cuda:{cuda_device}")
        torch.cuda.set_device(device)

        engine = TransferEngine()
        hostname = _local_ip()
        _check_ret(
            "target TransferEngine.initialize",
            engine.initialize(hostname, "P2PHANDSHAKE", "rdma", devices),
        )
        session_id = f"{hostname}:{engine.get_rpc_port()}"

        target = torch.empty(nbytes, dtype=torch.uint8, device=device)
        target.zero_()
        torch.cuda.synchronize(device)

        target_ptr = target.data_ptr()
        _check_ret(
            "target batch_register_memory",
            engine.batch_register_memory([target_ptr], [target.numel()]),
        )

        ready_q.put(
            {
                "session_id": session_id,
                "target_ptr": target_ptr,
                "nbytes": target.numel(),
            }
        )

        command = command_q.get(timeout=30)
        if command != "verify":
            raise RuntimeError(f"unexpected target command: {command}")

        torch.cuda.synchronize(device)
        expected = _make_pattern(torch, nbytes, device)
        if not torch.equal(target, expected):
            mismatch = (target != expected).nonzero()
            first = int(mismatch[0].item()) if mismatch.numel() else -1
            raise RuntimeError(
                f"target tensor mismatch at byte {first}: "
                f"got={int(target[first].item()) if first >= 0 else 'n/a'} "
                f"expected={int(expected[first].item()) if first >= 0 else 'n/a'}"
            )

        _check_ret("target batch_unregister_memory", engine.batch_unregister_memory([target_ptr]))
        result_q.put({"ok": True})
    except Exception:
        result_q.put({"ok": False, "traceback": traceback.format_exc()})


def _source_worker(devices, cuda_device, nbytes, target_info, result_q):
    try:
        import torch
        from mooncake.engine import TransferEngine

        device = torch.device(f"cuda:{cuda_device}")
        torch.cuda.set_device(device)

        engine = TransferEngine()
        _check_ret(
            "source TransferEngine.initialize",
            engine.initialize(_local_ip(), "P2PHANDSHAKE", "rdma", devices),
        )

        source = _make_pattern(torch, nbytes, device)
        torch.cuda.synchronize(device)
        source_ptr = source.data_ptr()

        _check_ret(
            "source batch_register_memory",
            engine.batch_register_memory([source_ptr], [source.numel()]),
        )
        _check_ret(
            "source batch_transfer_sync_write",
            engine.batch_transfer_sync_write(
                target_info["session_id"],
                [source_ptr],
                [target_info["target_ptr"]],
                [target_info["nbytes"]],
            ),
        )
        _check_ret("source batch_unregister_memory", engine.batch_unregister_memory([source_ptr]))
        result_q.put({"ok": True})
    except Exception:
        result_q.put({"ok": False, "traceback": traceback.format_exc()})


def _get_result(result_q, name, timeout=45):
    try:
        result = result_q.get(timeout=timeout)
    except queue.Empty:
        _fail(f"{name} timed out")
    if not result.get("ok"):
        _fail(f"{name} failed\n{result.get('traceback', '')}")


def main():
    try:
        import torch
    except ImportError as exc:
        _fail(f"torch import failed: {exc}")

    if not torch.cuda.is_available():
        _fail("CUDA is not available")

    devices = os.environ["RDMA_EXPECTED_DEVICES"]
    cuda_device = int(os.environ.get("RDMA_TENSOR_CUDA_DEVICE", "0"))
    nbytes = int(os.environ.get("RDMA_TENSOR_NUM_BYTES", "1024"))
    if nbytes <= 0:
        _fail("RDMA_TENSOR_NUM_BYTES must be positive")

    mp.set_start_method("spawn", force=True)
    ready_q = mp.Queue()
    command_q = mp.Queue()
    target_result_q = mp.Queue()
    source_result_q = mp.Queue()

    target = mp.Process(
        target=_target_worker,
        args=(devices, cuda_device, nbytes, ready_q, command_q, target_result_q),
    )
    target.start()

    try:
        target_info = ready_q.get(timeout=45)
    except queue.Empty:
        target.terminate()
        target.join(timeout=5)
        _fail("target worker did not publish Mooncake session")

    source = mp.Process(
        target=_source_worker,
        args=(devices, cuda_device, nbytes, target_info, source_result_q),
    )
    source.start()
    _get_result(source_result_q, "source worker")
    source.join(timeout=5)

    command_q.put("verify")
    _get_result(target_result_q, "target worker")
    target.join(timeout=5)

    if source.exitcode not in (0, None):
        _fail(f"source process exited with {source.exitcode}")
    if target.exitcode not in (0, None):
        _fail(f"target process exited with {target.exitcode}")

    print(
        "Mooncake tensor transfer check passed:",
        f"bytes={nbytes}",
        f"cuda_device={cuda_device}",
        f"devices={devices}",
        flush=True,
    )


if __name__ == "__main__":
    main()
