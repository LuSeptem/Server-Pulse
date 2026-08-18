import { ref, onMounted, onUnmounted } from 'vue'
import { invoke } from '@tauri-apps/api/core'
import { getCurrentWindow } from '@tauri-apps/api/window'
import type { UnlistenFn } from '@tauri-apps/api/event'

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
  // Default to true (auto-hide enabled), aligned 1:1 with legacy version
  const autoHideEnabled = ref(localStorage.getItem('serverpulse_autohide') !== 'false')
  const dockSide = ref<DockSide>('none')
  const isHidden = ref(false)
  const isHovering = ref(false)
  const isDragging = ref(false)
  const isAnimating = ref(false)

  const shownPos = ref<{ x: number; y: number } | null>(null)
  const savedWorkArea = ref<{ x: number; y: number; width: number; height: number; windowWidth: number; windowHeight: number } | null>(null)

  let hideTimer: number | null = null
  let moveDebounceTimer: number | null = null
  let pollInterval: number | null = null
  let isInternalMove = false
  let unlistenMove: UnlistenFn | null = null

  function clearHideTimer() {
    if (hideTimer !== null) {
      clearTimeout(hideTimer)
      hideTimer = null
    }
  }

  function toggleAutoHide() {
    autoHideEnabled.value = !autoHideEnabled.value
    localStorage.setItem('serverpulse_autohide', autoHideEnabled.value ? 'true' : 'false')
    if (!autoHideEnabled.value) {
      clearHideTimer()
      if (isHidden.value) {
        void reveal()
      }
    } else {
      void checkDocking(true)
    }
  }

  async function checkDocking(force = false) {
    // Never evaluate or overwrite docking positions while hidden, dragging, or animating!
    if (isHidden.value || isDragging.value || isInternalMove || isAnimating.value) return
    try {
      const bounds = await invoke<WindowMonitorBounds>('get_window_monitor_bounds')

      if (!autoHideEnabled.value) {
        dockSide.value = 'none'
        clearHideTimer()
        return
      }

      const scale = bounds.scaleFactor || 1.0
      const threshold = Math.max(35, Math.round(35 * scale))

      const leftDist = bounds.windowX - bounds.monitorX
      const rightDist = (bounds.monitorX + bounds.monitorWidth) - (bounds.windowX + bounds.windowWidth)
      const topDist = bounds.windowY - bounds.monitorY

      let side: DockSide = 'none'
      let targetX = bounds.windowX
      let targetY = bounds.windowY

      // Check left edge (within 35px or past left edge)
      if (leftDist <= threshold && leftDist >= -Math.round(bounds.windowWidth * 0.8)) {
        side = 'left'
        targetX = bounds.monitorX
      }
      // Check right edge (within 35px or past right edge)
      else if (rightDist <= threshold && rightDist >= -Math.round(bounds.windowWidth * 0.8)) {
        side = 'right'
        targetX = bounds.monitorX + bounds.monitorWidth - bounds.windowWidth
      }
      // Check top edge (within 35px or past top edge)
      else if (topDist <= threshold && topDist >= -Math.round(bounds.windowHeight * 0.8)) {
        side = 'top'
        targetY = bounds.monitorY
      }

      dockSide.value = side

      if (side !== 'none') {
        shownPos.value = { x: targetX, y: targetY }
        savedWorkArea.value = {
          x: bounds.monitorX,
          y: bounds.monitorY,
          width: bounds.monitorWidth,
          height: bounds.monitorHeight,
          windowWidth: bounds.windowWidth,
          windowHeight: bounds.windowHeight,
        }
        if (bounds.windowX !== targetX || bounds.windowY !== targetY) {
          isInternalMove = true
          await invoke('set_main_window_position', { x: targetX, y: targetY })
          isInternalMove = false
        }
        if (!isHovering.value && !options?.isMenuOpen?.() && !isHidden.value) {
          scheduleHide(600)
        }
      } else {
        shownPos.value = { x: bounds.windowX, y: bounds.windowY }
        savedWorkArea.value = null
        clearHideTimer()
      }
    } catch {
      isInternalMove = false
    }
  }

  async function hide() {
    if (!autoHideEnabled.value || dockSide.value === 'none' || isHidden.value || isDragging.value || isAnimating.value) {
      return
    }
    if (isHovering.value || options?.isMenuOpen?.()) {
      return
    }
    try {
      const bounds = await invoke<WindowMonitorBounds>('get_window_monitor_bounds')
      const scale = bounds.scaleFactor || 1.0
      // 8px visible handle strip at the edge (matching legacy WPF 7-8px)
      const handlePx = Math.max(8, Math.round(8 * scale))

      const basePos = shownPos.value || { x: bounds.windowX, y: bounds.windowY }
      const workArea = savedWorkArea.value || {
        x: bounds.monitorX,
        y: bounds.monitorY,
        width: bounds.monitorWidth,
        height: bounds.monitorHeight,
        windowWidth: bounds.windowWidth,
        windowHeight: bounds.windowHeight,
      }

      let hiddenX = basePos.x
      let hiddenY = basePos.y

      if (dockSide.value === 'left') {
        hiddenX = workArea.x - workArea.windowWidth + handlePx
        hiddenY = basePos.y
      } else if (dockSide.value === 'right') {
        hiddenX = workArea.x + workArea.width - handlePx
        hiddenY = basePos.y
      } else if (dockSide.value === 'top') {
        hiddenX = basePos.x
        hiddenY = workArea.y - workArea.windowHeight + handlePx
      }

      isAnimating.value = true
      isInternalMove = true
      isHidden.value = true
      await invoke('animate_main_window_position', {
        fromX: bounds.windowX,
        fromY: bounds.windowY,
        toX: hiddenX,
        toY: hiddenY,
        durationMs: 150,
      })
      isAnimating.value = false
      isInternalMove = false
    } catch {
      isAnimating.value = false
      isInternalMove = false
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
      isInternalMove = true
      isHidden.value = false
      await invoke('animate_main_window_position', {
        fromX: bounds.windowX,
        fromY: bounds.windowY,
        toX: shownPos.value.x,
        toY: shownPos.value.y,
        durationMs: 150,
      })
      isAnimating.value = false
      isInternalMove = false
      try {
        await getCurrentWindow().setAlwaysOnTop(true)
        await getCurrentWindow().setFocus()
      } catch {}
    } catch {
      isAnimating.value = false
      isInternalMove = false
      isHidden.value = false
    }
  }

  function scheduleHide(delayMs = 600) {
    clearHideTimer()
    if (!autoHideEnabled.value || dockSide.value === 'none' || isHidden.value || isDragging.value) {
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
    if (autoHideEnabled.value && dockSide.value !== 'none' && !options?.isMenuOpen?.()) {
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
    await checkDocking(true)
  }

  const handleWindowBlur = () => {
    isHovering.value = false
    if (autoHideEnabled.value && dockSide.value !== 'none' && !options?.isMenuOpen?.()) {
      scheduleHide(300)
    }
  }

  async function pollGlobalCursor() {
    if (isDragging.value || isAnimating.value) return
    try {
      const [cx, cy] = await invoke<[number, number]>('get_cursor_position')
      const workArea = savedWorkArea.value
      const pos = shownPos.value

      if (isHidden.value && dockSide.value !== 'none' && workArea && pos) {
        let touches = false
        const edgeThreshold = 24

        if (dockSide.value === 'right') {
          touches =
            cx >= workArea.x + workArea.width - edgeThreshold &&
            cy >= pos.y - 30 &&
            cy <= pos.y + workArea.windowHeight + 30
        } else if (dockSide.value === 'left') {
          touches =
            cx <= workArea.x + edgeThreshold &&
            cy >= pos.y - 30 &&
            cy <= pos.y + workArea.windowHeight + 30
        } else if (dockSide.value === 'top') {
          touches =
            cy <= workArea.y + edgeThreshold &&
            cx >= pos.x - 30 &&
            cx <= pos.x + workArea.windowWidth + 30
        }

        if (touches) {
          isHovering.value = true
          void reveal()
        }
      } else if (!isHidden.value && dockSide.value !== 'none' && workArea && pos) {
        // When shown, check if cursor is inside the window
        const insideWindow =
          cx >= pos.x &&
          cx <= pos.x + workArea.windowWidth &&
          cy >= pos.y &&
          cy <= pos.y + workArea.windowHeight

        if (insideWindow) {
          isHovering.value = true
          clearHideTimer()
        } else if (isHovering.value && !options?.isMenuOpen?.()) {
          isHovering.value = false
          scheduleHide(600)
        }
      }
    } catch {
      // Fallback
    }
  }

  onMounted(async () => {
    window.addEventListener('blur', handleWindowBlur)
    try {
      unlistenMove = await getCurrentWindow().onMoved(() => {
        if (isHidden.value || isInternalMove || isAnimating.value) return
        if (moveDebounceTimer !== null) {
          clearTimeout(moveDebounceTimer)
        }
        moveDebounceTimer = window.setTimeout(() => {
          if (!isHidden.value && !isInternalMove && !isAnimating.value) {
            void checkDocking(true)
          }
        }, 120)
      })
    } catch {
      // Listener fallback
    }

    // High precision polling for global cursor tracking (75ms), matching legacy $cursorTimer
    pollInterval = window.setInterval(() => {
      void pollGlobalCursor()
    }, 75)

    void checkDocking(true)
  })

  onUnmounted(() => {
    window.removeEventListener('blur', handleWindowBlur)
    clearHideTimer()
    if (moveDebounceTimer !== null) {
      clearTimeout(moveDebounceTimer)
    }
    if (pollInterval !== null) {
      clearInterval(pollInterval)
    }
    if (unlistenMove) {
      unlistenMove()
      unlistenMove = null
    }
  })

  return {
    autoHideEnabled,
    dockSide,
    isHidden,
    isHovering,
    toggleAutoHide,
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
