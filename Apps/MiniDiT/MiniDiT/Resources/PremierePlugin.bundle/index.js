const fs = require("fs"), ppro = require("premierepro"), uxp = require("uxp");
const { createReceiver } = require("./receiver.js"), { createMailbox } = require("./mailbox.js");
const base = require("os").homedir() + "/Library/Application Support/MiniDiT/Premiere";
let worker, timer, heart, starting;
/* 跟随 Premiere 的界面语言：zh 开头显示中文，其余显示英文。 */
const zh = (() => {
    let locale = "";
    try { locale = uxp.host.uiLocale || ""; } catch (_) {}
    if (!locale && typeof navigator !== "undefined") locale = navigator.language || "";
    return /^zh/i.test(locale);
})();
const t = (c, e) => zh ? c : e;
function status(text, project = "") { document.getElementById("status").textContent = text; document.getElementById("project").textContent = project; }
async function identity(path) {
    try {
        const stat = await fs.lstat(path);
        if (stat.dev != null && stat.ino != null && stat.ino !== 0) return "file:" + stat.dev + ":" + stat.ino;
    } catch (_) {}
    // MiniDiT sends resolved native paths. Normalize the common macOS /var alias for existing items.
    return path.replace(/^\/var\//, "/private/var/").replace(/\/$/, "");
}
async function exists(path) { try { await fs.lstat(path); return true; } catch (_) { return false; } }
async function makeParent(path) { await fs.mkdir(path.slice(0, path.lastIndexOf("/")), { recursive: true }); }
async function start() {
    if (worker) return;
    if (starting) return starting;
    starting = (async () => {
        await fs.mkdir(base + "/requests", { recursive: true });
        worker = createMailbox(fs, base, createReceiver(ppro, { identity, exists, makeParent, zh }), { zh });
        async function beat() {
            try {
                const project = await worker.heartbeat();
                status(worker.isBusy() ? t("正在接收素材…", "Receiving media…") : t("已连接，等待素材", "Connected. Waiting for media."), project ? t("当前项目：", "Current project: ") + project.name : "");
            } catch (error) { status(t("连接失败：", "Connection failed: ") + String(error.message || error)); }
        }
        await beat();
        timer = setInterval(() => { worker.tick().catch(error => status(String(error.message || error))); }, 500);
        heart = setInterval(beat, 2000);
    })();
    try { await starting; } finally { starting = null; }
}
status(t("正在连接…", "Connecting…"));
uxp.entrypoints.setup({
    plugin: { create: start, destroy() { clearInterval(timer); clearInterval(heart); } },
    panels: { minidit: { show: start } }
});
