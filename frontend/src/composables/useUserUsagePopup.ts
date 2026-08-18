import { ref, computed } from 'vue'

export type UserUsageKind = 'cpu' | 'memory' | 'vram'

export interface UserUsageTargetInfo {
  serverId: string
  serverLabel: string
  kind: UserUsageKind
  gpuIndex?: number
  gpuName?: string
  totalMiB?: number
}

const currentTarget = ref<UserUsageTargetInfo | null>(null)
const isPinned = ref(false)
const isExpanded = ref(false)
const popupCoords = ref({ x: 0, y: 0 })
const isPopupHovered = ref(false)

let closeTimer: ReturnType<typeof setTimeout> | null = null

function cancelCloseTimer() {
  if (closeTimer) {
    clearTimeout(closeTimer)
    closeTimer = null
  }
}

function calculateCoords(el: HTMLElement) {
  const rect = el.getBoundingClientRect()
  const padding = 8
  const popupWidth = 280
  const popupHeight = 340

  let x = rect.left + rect.width + padding
  let y = rect.top

  if (x + popupWidth > window.innerWidth - padding) {
    x = rect.left - popupWidth - padding
  }
  if (x < padding) {
    x = Math.max(padding, Math.min(window.innerWidth - popupWidth - padding, rect.left))
    y = rect.bottom + padding
  }

  if (y + popupHeight > window.innerHeight - padding) {
    y = Math.max(padding, window.innerHeight - popupHeight - padding)
  }

  return { x: Math.round(x), y: Math.round(y) }
}

export function useUserUsagePopup() {
  const isOpen = computed(() => currentTarget.value !== null)

  function open(target: UserUsageTargetInfo, pinned: boolean, el: HTMLElement) {
    cancelCloseTimer()
    if (
      currentTarget.value?.serverId !== target.serverId ||
      currentTarget.value?.kind !== target.kind ||
      currentTarget.value?.gpuIndex !== target.gpuIndex
    ) {
      isExpanded.value = false
    }
    currentTarget.value = target
    isPinned.value = pinned
    popupCoords.value = calculateCoords(el)
  }

  function close(force = false) {
    cancelCloseTimer()
    if (!force && isPinned.value) {
      return
    }
    currentTarget.value = null
    isPinned.value = false
    isExpanded.value = false
    isPopupHovered.value = false
  }

  function scheduleClose(delayMs = 350) {
    cancelCloseTimer()
    if (isPinned.value) return
    closeTimer = setTimeout(() => {
      if (!isPopupHovered.value && !isPinned.value) {
        close(true)
      }
    }, delayMs)
  }

  function onTargetMouseEnter(target: UserUsageTargetInfo, el: HTMLElement) {
    cancelCloseTimer()
    if (!isPinned.value) {
      open(target, false, el)
    }
  }

  function onTargetMouseLeave() {
    if (!isPinned.value) {
      scheduleClose(350)
    }
  }

  function onTargetClick(target: UserUsageTargetInfo, el: HTMLElement) {
    cancelCloseTimer()
    const isSame =
      currentTarget.value?.serverId === target.serverId &&
      currentTarget.value?.kind === target.kind &&
      currentTarget.value?.gpuIndex === target.gpuIndex

    if (isSame && isPinned.value) {
      close(true)
    } else {
      open(target, true, el)
    }
  }

  function onPopupMouseEnter() {
    isPopupHovered.value = true
    cancelCloseTimer()
  }

  function onPopupMouseLeave() {
    isPopupHovered.value = false
    if (!isPinned.value) {
      scheduleClose(350)
    }
  }

  function toggleExpand() {
    isExpanded.value = !isExpanded.value
  }

  function unpin() {
    close(true)
  }

  return {
    isOpen,
    currentTarget,
    isPinned,
    isExpanded,
    popupCoords,
    open,
    close,
    onTargetMouseEnter,
    onTargetMouseLeave,
    onTargetClick,
    onPopupMouseEnter,
    onPopupMouseLeave,
    toggleExpand,
    unpin,
  }
}
