// Disk-mount display helpers shared by the History view.
//
// Minute records written before the sampler gained fstype filtering (and
// records merged from agents that have not been Restart/Inject-ed yet) can
// still carry snap squashfs loop mounts (/snap/<name>/<revision>). Those are
// virtual loop-back mounts, not real capacity, so they are hidden from
// display everywhere history is rendered.

/** Mount prefixes that are never shown as disk capacity. */
const HIDDEN_MOUNT_PREFIXES = ['/snap/']

export function isDisplayableDiskMount(mount: string): boolean {
  if (!mount) return false
  return !HIDDEN_MOUNT_PREFIXES.some((prefix) => mount.startsWith(prefix))
}

export interface ParsedDiskEntry {
  mount: string
  percent: number | null
  usedMib: number | null
}

export function parseDiskEntries(s: any): ParsedDiskEntry[] {
  const list = Array.isArray(s?.Disks) ? s.Disks : (Array.isArray(s?.disks) ? s.disks : [])
  return list
    .map((d: any): ParsedDiskEntry => ({
      mount: String(d.Mount ?? d.mount ?? ''),
      percent: typeof d.Percent === 'number' ? d.Percent : (typeof d.percent === 'number' ? d.percent : null),
      // Live-monitor history lines use UsedMib; agent minute records use UsedMiB.
      usedMib: typeof d.UsedMiB === 'number' ? d.UsedMiB : (typeof d.UsedMib === 'number' ? d.UsedMib : (typeof d.usedMib === 'number' ? d.usedMib : null)),
    }))
    .filter((entry: ParsedDiskEntry) => isDisplayableDiskMount(entry.mount))
}

export interface DiskUserAttributionRecord {
  scannedAt: string
  users: Array<{ uid: string; name: string; usedMib: number }>
}

export interface DiskUserSeries {
  name: string
  points: Array<[string, number]>
}

/**
 * Build the top-N per-user disk-attribution series for the History disk view.
 *
 * Records are grouped by scan instant (one attribution record exists per
 * mount, so a single scan produces several records with close timestamps —
 * users found on multiple mounts are summed within one instant). Points are
 * ordered by scan time and labelled through `labelFor`. Users are ranked by
 * their TOTAL usage (not name) so tiny system service accounts never crowd
 * out real consumers.
 */
export function buildTopDiskUserSeries(
  records: DiskUserAttributionRecord[],
  labelFor: (scannedAt: string) => string,
  maxUsers = 3,
): DiskUserSeries[] {
  interface ScanInstant {
    order: number
    label: string
    users: Map<string, { uid: string; name: string; usedMib: number }>
  }

  const scans = new Map<string, ScanInstant>()
  for (const record of records) {
    let instant = scans.get(record.scannedAt)
    if (!instant) {
      const parsedMs = Date.parse(record.scannedAt)
      instant = {
        order: Number.isNaN(parsedMs) ? Number.MAX_SAFE_INTEGER : parsedMs,
        label: labelFor(record.scannedAt),
        users: new Map(),
      }
      scans.set(record.scannedAt, instant)
    }
    for (const u of record.users) {
      const userKey = u.uid || u.name
      const existing = instant.users.get(userKey)
      if (existing) {
        existing.usedMib += u.usedMib
      } else {
        instant.users.set(userKey, { uid: u.uid, name: u.name, usedMib: u.usedMib })
      }
    }
  }

  const byUser = new Map<string, { name: string; points: Array<[string, number]>; total: number }>()
  for (const instant of Array.from(scans.values()).sort((a, b) => a.order - b.order)) {
    for (const u of instant.users.values()) {
      const userKey = u.uid || u.name
      let entry = byUser.get(userKey)
      if (!entry) {
        entry = { name: u.name, points: [], total: 0 }
        byUser.set(userKey, entry)
      }
      entry.points.push([instant.label, u.usedMib / 1024])
      entry.total += u.usedMib
    }
  }

  return Array.from(byUser.values())
    .sort((a, b) => b.total - a.total || a.name.localeCompare(b.name))
    .slice(0, maxUsers)
    .map(({ name, points }) => ({ name, points }))
}

/**
 * Expand sparse scan points onto a dense category axis with step semantics:
 * every axis slot after a point holds that point's value (the last scan in
 * effect), slots before the first point stay null (no data yet). Points whose
 * label is not on the axis are ignored.
 */
export function expandCarriedForward(
  axisLabels: string[],
  points: Array<[string, number]>,
): Array<number | null> {
  const valueByLabel = new Map<string, number>()
  for (const [label, value] of points) {
    valueByLabel.set(label, value)
  }
  let current: number | null = null
  return axisLabels.map((label) => {
    if (valueByLabel.has(label)) {
      current = valueByLabel.get(label)!
    }
    return current
  })
}
