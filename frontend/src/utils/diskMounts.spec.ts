import { describe, expect, it } from 'vitest'
import { parseDiskEntries, buildTopDiskUserSeries } from './diskMounts'

describe('parseDiskEntries', () => {
  it('keeps real filesystems and drops snap loop mounts', () => {
    const entries = parseDiskEntries({
      Disks: [
        { Mount: '/data/data4', Percent: 63.1, UsedMiB: 9544372 },
        { Mount: '/snap/nvtop/344', Percent: 100, UsedMib: 100 },
        { Mount: '/snap/core18/2979', Percent: 100 },
      ],
    })
    expect(entries).toHaveLength(1)
    expect(entries[0].mount).toBe('/data/data4')
    // Live-monitor history lines use UsedMib; agent minute records use UsedMiB.
    expect(entries[0].usedMib).toBe(9544372)
  })

  it('treats a sample containing only snap mounts as having no displayable disks', () => {
    const entries = parseDiskEntries({ Disks: [{ Mount: '/snap/foo/1', Percent: 100 }] })
    expect(entries).toHaveLength(0)
  })

  it('drops unnamed mounts', () => {
    const entries = parseDiskEntries({ Disks: [{ Mount: '', Percent: 50 }] })
    expect(entries).toHaveLength(0)
  })
})

describe('buildTopDiskUserSeries', () => {
  const record = (scannedAt: string, users: Array<{ uid: string; name: string; usedMib: number }>) => ({
    scannedAt,
    users,
  })

  it('ranks users by total usage instead of name', () => {
    const series = buildTopDiskUserSeries(
      [
        record('2026-08-22T08:00:00Z', [
          { uid: '1000', name: 'alice', usedMib: 14_000_000 },
          { uid: '1042', name: '_apt', usedMib: 1 },
        ]),
      ],
      (t) => t,
    )
    // Ranked by usage (alice first) even though "_apt" sorts before it alphabetically.
    expect(series.map((s) => s.name)).toEqual(['alice', '_apt'])
  })

  it('caps at three users keeping the biggest consumers', () => {
    const series = buildTopDiskUserSeries(
      [
        record('2026-08-22T08:00:00Z', [
          { uid: '1000', name: 'alice', usedMib: 9_000_000 },
          { uid: '1001', name: 'bob', usedMib: 4_000_000 },
          { uid: '33', name: 'www-data', usedMib: 500 },
          { uid: '1042', name: '_apt', usedMib: 1 },
        ]),
      ],
      (t) => t,
    )
    expect(series.map((s) => s.name)).toEqual(['alice', 'bob', 'www-data'])
    expect(series[0].points).toEqual([['2026-08-22T08:00:00Z', 9_000_000 / 1024]])
  })

  it('sums one user across mounts within the same scan instant', () => {
    const series = buildTopDiskUserSeries(
      [
        record('2026-08-22T08:00:00Z', [
          { uid: '1000', name: 'alice', usedMib: 1024 },
        ]),
        record('2026-08-22T08:00:03Z', [
          { uid: '1000', name: 'alice', usedMib: 2048 },
        ]),
      ],
      (t) => t,
    )
    // Same scan instant (per-scan grouping keys on scannedAt): distinct
    // instants stay separate points; the ranking sums across all points.
    expect(series).toHaveLength(1)
    expect(series[0].points).toHaveLength(2)
  })

  it('orders points by scan time and labels via labelFor', () => {
    const series = buildTopDiskUserSeries(
      [
        record('2026-08-22T09:00:00Z', [{ uid: '1000', name: 'alice', usedMib: 3072 }]),
        record('2026-08-22T08:00:00Z', [{ uid: '1000', name: 'alice', usedMib: 1024 }]),
      ],
      (t) => `L:${t}`,
    )
    expect(series[0].points.map((p) => p[0])).toEqual(['L:2026-08-22T08:00:00Z', 'L:2026-08-22T09:00:00Z'])
  })
})
