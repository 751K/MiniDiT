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
    /* 与 MiniDiT 项目同名的 .prproj：当前打开的就是它就直接用；文件已存在就打开；都没有就新建。
       重试（带 projectID）只认第一次的项目：找不到不新建，换成了别的项目就拒绝。
       旧版本的请求没有目标项目，仍然发到当前项目。 */
    async function target(request) {
        const want = request.handoff.project;
        const active = await ppro.Project.getActiveProject();
        if (!want) {
            if (!active || !request.projectID || projectInfo(active).id !== request.projectID) throw new Error("Premiere Pro 项目已切换，请打开原项目后重试。");
            return { project: active, created: false };
        }
        if (typeof want.name !== "string" || typeof want.path !== "string" || !want.path.startsWith("/") || !want.path.endsWith(".prproj")) throw new Error("目标项目无效。");
        const same = project => project && (project.path || "") === want.path;
        let project = same(active) ? active : null, created = false;
        if (!project) {
            if (await io.exists(want.path)) {
                const options = ppro.OpenProjectOptions ? new ppro.OpenProjectOptions() : undefined;
                if (options) { options.setShowLocateFileDialog?.(false); options.setShowWarningDialog?.(false); options.setAddToMRUList?.(true); }
                project = await ppro.Project.open(want.path, options);
            } else if (request.projectID) {
                throw new Error("未找到原项目“" + want.name + "”，未导入素材。");
            } else {
                await io.makeParent(want.path);
                project = await ppro.Project.createProject(want.path);
                created = true;
            }
        }
        if (!project) throw new Error("无法打开 Premiere Pro 项目“" + want.name + "”。");
        if (request.projectID && projectInfo(project).id !== request.projectID) throw new Error("Premiere Pro 中的“" + want.name + "”已非原项目，未导入素材。");
        return { project, created };
    }
    async function receive(request, active = async () => {}) {
        if (request.action === "identify") return identify();
        if (request.action !== "import" || request.handoff?.version !== 1) throw new Error("不支持的发送请求。");
        const { project, created } = await target(request);
        const projectID = projectInfo(project).id;
        if (!projectID) throw new Error("Premiere Pro 未提供项目标识。");
        /* 按目标项目发送时，只要该项目仍然打开就继续（切换到其他项目不影响导入到它）；旧请求仍要求当前项目不变。 */
        async function check() {
            await active();
            const byTarget = request.handoff.project && ppro.Project.getProject;
            const current = byTarget ? await ppro.Project.getProject(project.guid) : await ppro.Project.getActiveProject();
            if (!current || projectInfo(current).id !== projectID || projectInfo(project).id !== projectID) {
                throw new Error(byTarget ? "Premiere Pro 项目“" + project.name + "”已关闭，导入未完成，可重试。" : "Premiere Pro 项目已切换，请打开原项目后重试。");
            }
        }
        const result = { project: project.name, projectID, created, imported: 0, skipped: 0, proxies: 0, receivedPaths: [], failedPaths: [], warnings: [] };
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
        if (!(await project.save())) result.warnings.push("项目未能自动保存，请在 Premiere Pro 中保存。");
        return result;
    }
    return { identify, receive };
}
module.exports = { createReceiver };
