import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const QUESTION_TOOLS = new Set(["ask_user_question"]);

/**
 * Bridge Pi's native `ask_user_question` (OSC 7501) to:
 * 1) Herdr 0.9.x's `herdr:blocked` event bus so Herdr marks the pane as
 *    `blocked` while waiting for user answers (when running inside Herdr).
 * 2) `pi-atelier`'s `rpiv:ask-user:blocked` event bus so desktop input-needed
 *    notifications fire consistently when a question prompt opens.
 *
 * Safe to trim the Herdr half once terminal Herdr parses OSC 7501 natively.
 */
export default function herdrQuestionBlockedBridge(pi: ExtensionAPI): void {
  const inHerdr = process.env.HERDR_ENV === "1";
  const activeCalls = new Set<string>();

  const release = (toolCallId: string) => {
    if (!activeCalls.delete(toolCallId)) return;
    if (inHerdr) {
      pi.events.emit("herdr:blocked", { active: false });
    }
    if (activeCalls.size === 0) {
      pi.events.emit("rpiv:ask-user:blocked", { active: false });
    }
  };

  const releaseAll = () => {
    const count = activeCalls.size;
    if (count === 0) return;
    activeCalls.clear();
    if (inHerdr) {
      for (let i = 0; i < count; i += 1) {
        pi.events.emit("herdr:blocked", { active: false });
      }
    }
    pi.events.emit("rpiv:ask-user:blocked", { active: false });
  };

  pi.on("tool_execution_start", (event, ctx) => {
    if (ctx.mode !== "tui") return;
    if (!QUESTION_TOOLS.has(event.toolName)) return;
    const id = event.toolCallId;
    if (!id || activeCalls.has(id)) return;
    const wasEmpty = activeCalls.size === 0;
    activeCalls.add(id);
    if (inHerdr) {
      pi.events.emit("herdr:blocked", {
        active: true,
        label: "Waiting for user response",
      });
    }
    if (wasEmpty) {
      pi.events.emit("rpiv:ask-user:blocked", { active: true });
    }
  });

  pi.on("tool_execution_end", (event) => {
    if (event.toolCallId) release(event.toolCallId);
  });

  pi.on("agent_end", releaseAll);
  pi.on("agent_settled", releaseAll);
  pi.on("session_shutdown", releaseAll);
}
