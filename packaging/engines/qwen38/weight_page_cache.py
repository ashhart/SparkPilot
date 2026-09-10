def _sparkpilot_release_weight_pages(model_path):
    import os
    from pathlib import Path
    import stat

    root = Path(model_path)
    if root != Path('/model'):
        raise RuntimeError('Qwen weights must use the managed read-only model mount')
    shards = sorted(root.glob('*.safetensors'))
    if not shards:
        raise RuntimeError('No managed Qwen weight shards found')
    for shard in shards:
        descriptor = os.open(shard, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                raise RuntimeError('Qwen weight shard must be a regular file')
            os.posix_fadvise(descriptor, 0, 0, os.POSIX_FADV_DONTNEED)
        finally:
            os.close(descriptor)
