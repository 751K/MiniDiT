/* All communication stays in this user's MiniDiT support folder. No network or executable requests. */
function createMailbox(fs, base, receiver, options = {}) {
    const now = options.now || (() => Date.now() / 1000), version = "1.1.0";
    let busy = false, processing = false;
    const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    async function read(path) { return JSON.parse(await fs.readFile(path, { encoding: "utf-8" })); }
    async function write(path, value) {
        const temp = path + "." + Math.random().toString(16).slice(2) + ".tmp";
        await fs.writeFile(temp, JSON.stringify(value), { encoding: "utf-8" });
        await fs.rename(temp, path);
    }
    async function heartbeat() {
        let project = null;
        try { project = await receiver.identify(); } catch (_) {}
        await write(base + "/heartbeat.json", { protocolVersion: 1, pluginVersion: version, updatedAt: now(), busy: processing, project });
        return project;
    }
    async function tick() {
        if (busy) return;
        busy = true;
        try {
            const folders = await fs.readdir(base + "/requests");
            for (const id of folders.sort()) {
                if (!uuid.test(id)) continue;
                const dir = base + "/requests/" + id;
                let request;
                try { request = await read(dir + "/request.json"); } catch (_) { continue; }
                if (request.id !== id || request.protocolVersion !== 1 || !["identify", "import"].includes(request.action)) continue;
                async function active() {
                    const lease = await read(dir + "/lease.json");
                    if (request.expiresAt <= now() || lease.expiresAt <= now() || lease.id !== id) throw new Error("发送已停止，请在 MiniDiT 中重试。");
                }
                try { await active(); await fs.rename(dir + "/request.json", dir + "/processing.json"); } catch (_) { continue; }
                try {
                    processing = true;
                    await heartbeat();
                    const value = await receiver.receive(request, active);
                    await active();
                    await write(dir + "/result.json", { id, value });
                } catch (error) {
                    try { await write(dir + "/result.json", { id, error: String(error.message || error) }); } catch (_) {}
                } finally { processing = false; try { await heartbeat(); } catch (_) {} }
            }
        } finally { busy = false; }
    }
    return { tick, heartbeat, isBusy: () => processing };
}
module.exports = { createMailbox };
