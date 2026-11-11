const fs = require("fs"), ppro = require("premierepro"), uxp = require("uxp");
const { createReceiver } = require("./receiver.js"), { createMailbox } = require("./mailbox.js");
const base = require("os").homedir() + "/Library/Application Support/MiniDiT/Premiere";
let worker, timer, heart, starting;
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
        worker = createMailbox(fs, base, createReceiver(ppro, { identity, exists, makeParent }));
        async function beat() {
            try {
                const project = await worker.heartbeat();
                status(worker.isBusy() ? "正在接收素材…" : "已连接，等待素材", project ? "当前项目：" + project.name : "");
            } catch (error) { status("连接失败：" + String(error.message || error)); }
        }
        await beat();
        timer = setInterval(() => { worker.tick().catch(error => status(String(error.message || error))); }, 500);
        heart = setInterval(beat, 2000);
    })();
    try { await starting; } finally { starting = null; }
}
uxp.entrypoints.setup({
    plugin: { create: start, destroy() { clearInterval(timer); clearInterval(heart); } },
    panels: { minidit: { show: start } }
});
