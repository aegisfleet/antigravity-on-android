import { spawn } from "node:child_process"
import { accessSync, constants } from "node:fs"

const candidates = [
  process.env.TERMUX_NOTIFICATION_BIN,
  "/data/data/com.termux/files/usr/bin/termux-notification",
  "/usr/bin/termux-notification",
]

function notify() {
  const enabled = (process.env.TERMUX_NOTIFICATION ?? process.env.TERMUX_NOTIFY ?? "1")
    .trim()
    .toLowerCase()
  if (["0", "false", "no", "off"].includes(enabled)) return

  const binary = candidates.find((candidate) => {
    if (!candidate) return false
    try {
      accessSync(candidate, constants.X_OK)
      return true
    } catch {
      return false
    }
  })
  if (!binary) return

  const child = spawn(
    binary,
    [
      "-i",
      "opencode_task",
      "-t",
      "🧠 OpenCode 完了",
      "-c",
      "作業の処理が完了しました。",
      "--priority",
      "high",
      "--sound",
    ],
    { stdio: "ignore", detached: true },
  )
  child.on("error", () => {})
  child.unref()
}

export default {
  id: "aegisfleet.termux-notifications",
  setup(ctx) {
    const controller = new AbortController()
    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({
          types: ["session.idle"],
          signal: controller.signal,
        })) {
          if (event.type === "session.idle") notify()
        }
      } catch (error) {
        if (!controller.signal.aborted) {
          console.error("[Termux notifications] OpenCode event subscription failed:", error)
        }
      }
    })()
    return () => controller.abort()
  },
}
