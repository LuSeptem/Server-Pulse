import { ref, onMounted, onUnmounted } from 'vue'
import { invoke } from '@tauri-apps/api/core'
import { listen, type UnlistenFn } from '@tauri-apps/api/event'

export type DockSide = 'none' | 'left' | 'right' | 'top'

export interface EdgeDockState {
  dockSide: DockSide
  isHidden: boolean
  autoHideEnabled: boolean
  shownX: number
  shownY: number
  winWidth: number
  winHeight: number
}

export function useEdgeDocking() {
  const autoHideEnabled = ref(true)
  const dockSide = ref<DockSide>('none')
  const isHidden = ref(false)

  let unlisten: UnlistenFn | null = null

  async function toggleAutoHide() {
    try {
      const res = await invoke<EdgeDockState>('toggle_edge_dock_autohide')
      autoHideEnabled.value = res.autoHideEnabled
      dockSide.value = res.dockSide
      isHidden.value = res.isHidden
    } catch {
      autoHideEnabled.value = !autoHideEnabled.value
    }
  }

  onMounted(async () => {
    try {
      const initial = await invoke<EdgeDockState>('get_edge_dock_state')
      autoHideEnabled.value = initial.autoHideEnabled
      dockSide.value = initial.dockSide
      isHidden.value = initial.isHidden
    } catch {
      // Fallback
    }

    try {
      unlisten = await listen<EdgeDockState>('edge_dock_state', (event) => {
        autoHideEnabled.value = event.payload.autoHideEnabled
        dockSide.value = event.payload.dockSide
        isHidden.value = event.payload.isHidden
      })
    } catch {
      // Fallback
    }
  })

  onUnmounted(() => {
    if (unlisten) {
      unlisten()
      unlisten = null
    }
  })

  return {
    autoHideEnabled,
    dockSide,
    isHidden,
    toggleAutoHide,
  }
}
