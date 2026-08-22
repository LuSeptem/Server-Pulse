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
