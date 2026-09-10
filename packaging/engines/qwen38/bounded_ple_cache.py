"""Bound packed-table page residency between synchronous PLE gathers."""
import mmap as _sparkpilot_mmap
import os


def _sparkpilot_prefetch_rows(embedding, ids, row_width):
    # A 90-byte row touches at most two 4 KiB pages; allow at most 512 MiB.
    row_budget = 65536
    count = ids.numel()
    if os.sysconf('SC_PAGE_SIZE') != 4096 or row_width != 90 or not 0 <= count <= row_budget:
        raise RuntimeError('PLE gather exceeds the qualified page-cache budget')
    consumed = getattr(embedding, '_sparkpilot_cached_rows', None)
    descriptor = embedding._packed_table_fd
    if consumed is None or consumed + count > row_budget:
        embedding._packed_table_mmap._mmap.madvise(_sparkpilot_mmap.MADV_DONTNEED)
        os.posix_fadvise(descriptor, 0, 0, os.POSIX_FADV_DONTNEED)
        consumed = 0
    embedding._sparkpilot_cached_rows = consumed + count
    _ple_prefetch_rows(descriptor, ids, row_width)
