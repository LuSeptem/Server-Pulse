import { describe, expect, it } from 'vitest'
import { parseDiskEntries } from './diskMounts'

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
