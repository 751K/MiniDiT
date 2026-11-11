/* Official Premiere UXP API only. Import into bins; never edit a timeline or run supplied code. */
function createReceiver(ppro, io) {
    const projectInfo = project => ({ id: project.guid.toString(), name: project.name, path: project.path || "" });
    async function identify() {
        const project = await ppro.Project.getActiveProject();
        if (!project) throw new Error("请先在 Premiere Pro 中打开目标项目。");
        const info = projectInfo(project);
        if (!info.id) throw new Error("Premiere Pro 未提供项目标识。");
        return info;
    }
    async function receive(request, active = async () => {}) {
        if (request.action === "identify") return identify();
        if (request.action !== "import" || !request.projectID || request.handoff?.version !== 1) throw new Error("不支持的发送请求。");
        const project = await ppro.Project.getActiveProject();
        if (!project || projectInfo(project).id !== request.projectID) throw new Error("Premiere Pro 项目已切换，请打开原项目后重试。");
        async function check() {
            await active();
            const current = await ppro.Project.getActiveProject();
            if (!current || projectInfo(current).id !== request.projectID || projectInfo(project).id !== request.projectID) {
                throw new Error("Premiere Pro 项目已切换，请打开原项目后重试。");
            }
        }
        const result = { project: project.name, projectID: request.projectID, imported: 0, skipped: 0, proxies: 0, receivedPaths: [], failedPaths: [], warnings: [] };
        const root = await project.getRootItem();
        function folder(item) { try { return ppro.FolderItem.cast(item); } catch (_) { return null; } }
        function clip(item) { try { return ppro.ClipProjectItem.cast(item); } catch (_) { return null; } }
        async function inventory() {
            const found = new Map(), stack = [root];
            while (stack.length) {
                await check();
                for (const item of await stack.pop().getItems()) {
                    const bin = folder(item);
                    if (bin) { stack.push(bin); continue; }
                    const media = clip(item);
                    if (!media || await media.isSequence()) continue;
                    const path = await media.getMediaFilePath();
                    if (path) found.set(await io.identity(path), media);
                }
            }
            return found;
        }
        function transaction(title, action) {
            let ok = false;
            project.lockedAccess(() => { ok = project.executeTransaction(compound => compound.addAction(action()), title); });
            if (!ok) throw new Error(title + "失败。");
        }
        async function ensureBin(names) {
            let parent = root;
            for (const name of names) {
                await check();
                if (typeof name !== "string" || !name.trim() || name.length > 512) throw new Error("素材箱名称无效。");
                let child = (await parent.getItems()).map(folder).find(f => f && f.name === name);
                if (!child) {
                    const target = parent;
                    transaction("创建 MiniDiT 素材箱", () => target.createBinAction(name, false));
                    child = (await parent.getItems()).map(folder).find(f => f && f.name === name);
                }
                if (!child) throw new Error("无法创建素材箱：" + name);
                parent = child;
            }
            return parent;
        }
        let existing = await inventory();
        for (const group of request.handoff.groups) {
            await check();
            const pending = [];
            for (const source of group.clips) {
                if (!source.path?.startsWith("/") || !source.canonicalPath?.startsWith("/")) throw new Error("素材路径无效。");
                const key = await io.identity(source.canonicalPath);
                if (!existing.has(key)) pending.push(source);
            }
            const before = new Set(existing.keys());
            if (pending.length) {
                const bin = await ensureBin(group.binPath);
                await check();
                try { await project.importFiles(pending.map(c => c.canonicalPath), true, ppro.ProjectItem.cast(bin), false); }
                catch (error) { result.warnings.push("部分素材导入时出现错误：" + String(error.message || error)); }
                // The API's boolean result alone is not a per-file receipt.
                existing = await inventory();
            }
            for (const source of group.clips) {
                await check();
                const key = await io.identity(source.canonicalPath), item = existing.get(key);
                if (!item || await item.isOffline()) { result.failedPaths.push(source.path); continue; }
                result.receivedPaths.push(source.path);
                if (before.has(key)) result.skipped++; else result.imported++;
                try {
                    if (source.proxy) {
                        await check();
                        const current = await item.getProxyPath();
                        if (!current && await item.canProxy()) await item.attachProxy(source.canonicalProxyPath, false);
                        const linked = await item.getProxyPath();
                        if (linked && await io.identity(linked) === await io.identity(source.canonicalProxyPath)) result.proxies++;
                        else result.warnings.push(source.path + "：代理未能关联；已有的代理设置已保留。");
                    }
                    if (source.marks?.length) {
                        const markers = await ppro.Markers.getMarkers(item);
                        let known = markers.getMarkers();
                        for (const mark of source.marks) {
                            await check();
                            const near = known.filter(m => Math.abs(m.getStart().seconds - mark.seconds) < mark.duration / 2);
                            if (near.some(m => m.getName() === mark.name)) continue;
                            if (near.length) { result.warnings.push(source.path + "：标记位置已被使用，保留了原标记。"); continue; }
                            transaction("添加 MiniDiT 拍摄标记", () => markers.createAddMarkerAction(mark.name, "Comment", ppro.TickTime.createWithSeconds(mark.seconds), ppro.TickTime.createWithSeconds(mark.duration), "MiniDiT"));
                            known = markers.getMarkers();
                        }
                    }
                } catch (error) {
                    await check();
                    result.warnings.push(source.path + "：" + String(error.message || error));
                }
            }
        }
        await check();
        return result;
    }
    return { identify, receive };
}
module.exports = { createReceiver };
