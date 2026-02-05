// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

// Define hooks
const Hooks = {}

// Auto-scroll to bottom when new messages arrive
Hooks.ScrollBottom = {
  mounted() {
    this.scrollToBottom()
    this.observer = new MutationObserver(() => this.scrollToBottom())
    this.observer.observe(this.el, { childList: true, subtree: true })
  },
  updated() {
    this.scrollToBottom()
  },
  destroyed() {
    if (this.observer) {
      this.observer.disconnect()
    }
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  }
}

// Message container hook - combines scroll, image viewer, and code copy
Hooks.MessageContainer = {
  mounted() {
    this.scrollToBottom()
    this.observer = new MutationObserver(() => {
      this.scrollToBottom()
      this.setupImageListeners()
      this.setupCopyButtons()
    })
    this.observer.observe(this.el, { childList: true, subtree: true })
    this.setupImageListeners()
    this.setupCopyButtons()
    
    // 监听页面可见性变化 - 当用户切换回来时重新同步
    this.visibilityHandler = () => {
      if (document.visibilityState === 'visible') {
        // 延迟一点发送，确保 LiveView 连接已恢复
        // 使用更长的延迟和重试逻辑
        this.retrySync(0)
      } else {
        this.pushEvent("visibility_changed", { visible: false })
      }
    }
    document.addEventListener('visibilitychange', this.visibilityHandler)
    
    // 监听 LiveView 重连事件
    this.handleReconnect = () => {
      console.log("[ChatLive] LiveView reconnected, syncing messages...")
      setTimeout(() => {
        this.pushEvent("visibility_changed", { visible: true })
      }, 200)
    }
    window.addEventListener('phx:page-loading-stop', this.handleReconnect)
  },
  updated() {
    this.scrollToBottom()
    this.setupImageListeners()
    this.setupCopyButtons()
  },
  destroyed() {
    if (this.observer) {
      this.observer.disconnect()
    }
    if (this.visibilityHandler) {
      document.removeEventListener('visibilitychange', this.visibilityHandler)
    }
    if (this.handleReconnect) {
      window.removeEventListener('phx:page-loading-stop', this.handleReconnect)
    }
  },
  // 带重试的同步逻辑
  retrySync(attempt) {
    const maxAttempts = 3
    const delays = [100, 500, 1500]
    
    if (attempt >= maxAttempts) {
      console.warn("[ChatLive] Failed to sync after", maxAttempts, "attempts")
      return
    }
    
    setTimeout(() => {
      try {
        // 检查 liveSocket 连接状态
        if (window.liveSocket && window.liveSocket.isConnected()) {
          this.pushEvent("visibility_changed", { visible: true })
          console.log("[ChatLive] Sync event pushed successfully")
        } else {
          console.log("[ChatLive] Socket not connected, retrying...", attempt + 1)
          this.retrySync(attempt + 1)
        }
      } catch (e) {
        console.warn("[ChatLive] Push failed, retrying...", e)
        this.retrySync(attempt + 1)
      }
    }, delays[attempt] || 1000)
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  },
  setupImageListeners() {
    // Find all images in message content
    const images = this.el.querySelectorAll('.message-content img, .media-image')
    images.forEach(img => {
      if (!img.dataset.viewerSetup) {
        img.dataset.viewerSetup = 'true'
        img.style.cursor = 'pointer'
        img.addEventListener('click', (e) => {
          e.preventDefault()
          e.stopPropagation()
          this.openImageModal(img.src, img.alt || 'Image')
        })
      }
    })
  },
  openImageModal(src, alt) {
    // Create modal overlay
    const modal = document.createElement('div')
    modal.className = 'fixed inset-0 z-50 flex items-center justify-center bg-black/90 p-4'
    modal.innerHTML = `
      <button class="absolute top-4 right-4 text-white hover:text-gray-300 p-2 rounded-full bg-black/50 hover:bg-black/70 transition-colors" aria-label="Close">
        <svg class="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
        </svg>
      </button>
      <img src="${src}" alt="${alt}" class="max-w-full max-h-full object-contain rounded-lg shadow-2xl" />
      <a href="${src}" download class="absolute bottom-4 right-4 text-white hover:text-gray-300 p-2 rounded-full bg-black/50 hover:bg-black/70 transition-colors" aria-label="Download">
        <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4"/>
        </svg>
      </a>
    `
    // Close on click outside or button
    modal.addEventListener('click', (e) => {
      if (e.target === modal || e.target.closest('button[aria-label="Close"]')) {
        modal.remove()
      }
    })
    // Close on escape key
    const handleEscape = (e) => {
      if (e.key === 'Escape') {
        modal.remove()
        document.removeEventListener('keydown', handleEscape)
      }
    }
    document.addEventListener('keydown', handleEscape)
    document.body.appendChild(modal)
  },
  setupCopyButtons() {
    const codeBlocks = this.el.querySelectorAll('.code-block-wrapper')
    codeBlocks.forEach(wrapper => {
      const btn = wrapper.querySelector('button')
      const code = wrapper.querySelector('code')
      if (btn && code && !btn.dataset.copySetup) {
        btn.dataset.copySetup = 'true'
        btn.addEventListener('click', async (e) => {
          e.preventDefault()
          e.stopPropagation()
          try {
            await navigator.clipboard.writeText(code.textContent)
            // Show success feedback
            const originalHTML = btn.innerHTML
            btn.innerHTML = `<svg class="w-4 h-4 text-green-400" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/></svg>`
            btn.classList.add('copy-success')
            setTimeout(() => {
              btn.innerHTML = originalHTML
              btn.classList.remove('copy-success')
            }, 2000)
          } catch (err) {
            console.error('Failed to copy:', err)
          }
        })
      }
    })
  }
}

// Auto-resize textarea
Hooks.AutoResize = {
  mounted() {
    this.resize()
    this.el.addEventListener("input", () => this.resize())
  },
  updated() {
    this.resize()
  },
  resize() {
    this.el.style.height = "auto"
    this.el.style.height = Math.min(this.el.scrollHeight, 120) + "px"
  }
}

// Chat input: Enter sends, Shift/Alt+Enter for newline
Hooks.ChatInput = {
  mounted() {
    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey && !e.altKey) {
        e.preventDefault()
        // Auto-resize after preventing default
        this.resize()
        // Push the keydown event to LiveView
        this.pushEvent("keydown", {key: "Enter", shiftKey: false})
      }
    })
    this.el.addEventListener("input", () => this.resize())
    this.resize()
  },
  updated() {
    this.resize()
  },
  resize() {
    this.el.style.height = "auto"
    this.el.style.height = Math.min(this.el.scrollHeight, 120) + "px"
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks,
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#6366f1"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// Handle flash close
document.querySelectorAll("[role=alert][data-flash]").forEach((el) => {
  el.addEventListener("click", () => {
    el.setAttribute("hidden", "")
  })
})
