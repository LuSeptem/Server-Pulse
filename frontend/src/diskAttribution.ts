/**
 * 按用户磁盘归因功能冻结开关。
 *
 * Must be kept in sync with the Rust constant
 * `serverpulse_core::DISK_ATTRIBUTION_FROZEN` — the two sides gate the same
 * feature independently (backend refuses the work, frontend hides the
 * entry points).
 *
 * Frozen behavior:
 * - the find-based daily scanner is never deployed or scheduled,
 * - "立即扫描 / Scan now" is hidden and no scan polling runs,
 * - per-user disk attribution popups and History user curves are not
 *   rendered, and the 5-minute attribution auto-refresh is off,
 * - existing attribution history is preserved; only new writes stop.
 *
 * Real-time disk capacity (df-based DISK row, per-mount list, per-mount
 * history curves) is NOT part of this freeze.
 *
 * Flip to `false` (together with the Rust constant) to re-enable the
 * feature; when it is decommissioned, remove these code paths entirely.
 */
export const DISK_ATTRIBUTION_FROZEN = true
