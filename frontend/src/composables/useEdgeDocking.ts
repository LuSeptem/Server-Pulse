import { ref } from 'vue'
import { invoke } from '@tauri-apps/api/core'

export interface WindowMonitorBounds {
  monitorX: number
  monitorY: number
  monitorWidth: number
  monitorHeight: number
  scaleFactor: number
  windowX: number
  windowY: number
  windowWidth: number
  windowHeight: number
}

export type DockSide = 'none' | 'left' | 'right' | 'top'

export function useEdgeDocking(options?: {
  isMenuOpen?: () => boolean
}) {
  const isPinned = ref(localStorage.getItem('serverpulse_pinned') === 'true')
  const dockSide = ref<DockSide>('none')
  const isHidden = ref(false)
  const isHovering = ref(false)
  const isDragging = ref(false)
  const isAnimating = ref(false)

  const shownPos = ref<{ x: number; y: number } | null>(null)
  let hideTimer: number | null = null

  function clearHideTimer() {
    if (hideTimer !== null) {
      clearTimeout(hideTimer)
      hideTimer = null
    }
  }

  function togglePinned() {
    isPinned.value = !isPinned.value
    localStorage.setItem('serverpulse_pinned', isPinned.value ? 'true' : 'false')
    if (isPinned.value) {
      clearHideTimer()
      if (isHidden.value) {
        void reveal()
      }
    } else {
      void checkDocking()
    }
  }

  async function checkDocking() {
    if (isPinned.value || isDragging.value) return
    try {
      const bounds = await invoke<WindowMonitorBounds>('get_window_monitor_bounds')
      const scale = bounds.scaleFactor || 1.0
      const threshold = Math.round(25 * scale)

      const leftDist = bounds.windowX - bounds.monitorX
      const rightDist = (bounds.monitorX + bounds.monitorWidth) - (bounds.windowX + bounds.windowWidth)
      const topDist = bounds.windowY - bounds.monitorY

      let side: DockSide = 'none'
      let targetX = bounds.windowX
      let targetY = bounds.windowY

      if (leftDist <= threshold && leftDist >= -100) {
        side = 'left'
        targetX = bounds.monitorX
      } else if (rightDist <= threshold && rightDist >= -100) {
        side = 'right'
        targetX = bounds.monitorX + bounds.monitorWidth - bounds.windowWidth
      } else if (topDist <= threshold && topDist >= -100) {
        side = 'top'
        targetY = bounds.monitorY
      }

      dockSide.value = side

      if (side !== 'none') {
        shownPos.value = { x: targetX, y: targetY }
        await invoke('set_main_window_position', { x: targetX, y: targetY })
        if (!isHovering.value && !options?.isMenuOpen?.()) {
          scheduleHide(600)
        }
      } else {
        shownPos.value = { x: bounds.windowX, y: bounds.windowY }
        clearHideTimer()
      }
    } catch {
      // Window might not be ready or closed
    }
  }

  async function hide() {
    if (isPinned.value || dockSide.value === 'none' || isHidden.value || isDragging.value || isAnimating.value) {
      return
    }
    if (isHovering.value || options?.isMenuOpen?.()) {
      return
    }
    try {
      const bounds = await invoke<WindowMonitorBounds>('get_window_monitor_bounds')
      const scale = bounds.scaleFactor || 1.0
      const handlePx = Math.round(6 * scale)

      let hiddenX = bounds.windowX
      let hiddenY = bounds.windowY

      if (dockSide.value === 'left') {
        hiddenX = bounds.monitorX - bounds.windowWidth + handlePx
        hiddenY = shownPos.value ? shownPos.value.y : bounds.windowY
      } else if (dockSide.value === 'right') {
        hiddenX = bounds.monitorX + bounds.monitorWidth - handlePx
        hiddenY = shownPos.value ? shownPos.value.y : bounds.windowY
      } else if (dockSide.value === 'top') {
        hiddenX = shownPos.value ? shownPos.value.x : bounds.windowX
        hiddenY = bounds.monitorY - bounds.windowHeight + handlePx
      }

      isAnimating.value = true
      isHidden.value = true
      await invoke('animate_main_window_position', {
        fromX: bounds.windowX,
        fromY: bounds.windowY,
        toX: hiddenX,
        toY: hiddenY,
        durationMs: 150,
      })
      isAnimating.value = false
    } catch {
      isAnimating.value = false
    }
  }

  async function reveal() {
    clearHideTimer()
    if (!isHidden.value || !shownPos.value || isAnimating.value) {
      isHidden.value = false
      return
    }
    try {
      const bounds = await invoke<WindowMonitorBounds>('get_window_monitor_bounds')
      isAnimating.value = true
      isHidden.value = false
      await invoke('animate_main_window_position', {
        fromX: bounds.windowX,
        fromY: bounds.windowY,
        toX: shownPos.value.x,
        toY: shownPos.value.y,
        durationMs: 150,
      })
      isAnimating.value = false
    } catch {
      isAnimating.value = false
      isHidden.value = false
    }
  }

  function scheduleHide(delayMs = 600) {
    clearHideTimer()
    if (isPinned.value || dockSide.value === 'none' || isHidden.value || isDragging.value) {
      return
    }
    hideTimer = window.setTimeout(() => {
      void hide()
    }, delayMs)
  }

  function onMouseEnter() {
    isHovering.value = true
    clearHideTimer()
    if (isHidden.value) {
      void reveal()
    }
  }

  function onMouseLeave() {
    isHovering.value = false
    if (!isPinned.value && dockSide.value !== 'none' && !options?.isMenuOpen?.()) {
      scheduleHide(600)
    }
  }

  function onDragStart() {
    isDragging.value = true
    clearHideTimer()
    if (isHidden.value) {
      isHidden.value = false
    }
  }

  async function onDragEnd() {
    isDragging.value = false
    await checkDocking()
  }

  return {
    isPinned,
    dockSide,
    isHidden,
    isHovering,
    togglePinned,
    checkDocking,
    onMouseEnter,
    onMouseLeave,
    onDragStart,
    onDragEnd,
    scheduleHide,
    reveal,
    hide,
  }
}
