const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises'), os = require('node:os'), path = require('node:path');
const { createReceiver } = require('../../Apps/MiniDiT/MiniDiT/Resources/PremierePlugin.bundle/receiver.js');
const { createMailbox } = require('../../Apps/MiniDiT/MiniDiT/Resources/PremierePlugin.bundle/mailbox.js');
function fixture() {
    let active, imports = [], partial = true, binActions = 0, markerActions = 0, newProject;
    const files = new Set(), open = new Map(), log = [];
    const makeFolder = name => ({ kind: 'folder', name, items: [], async getItems() { return this.items; }, createBinAction(name) {
        binActions++; return () => this.items.push(makeFolder(name));
    } });
    const makeClip = file => ({ kind: 'clip', path: file, proxy: '', marks: [], async isSequence() { return false; },
        async isOffline() { return false; }, async getMediaFilePath() { return this.path; }, async canProxy() { return true; },
        async getProxyPath() { return this.proxy; }, async attachProxy(proxy, hiRes) { assert.equal(hiRes, false); this.proxy = proxy; return true; } });
    function project(id, file = '/' + id + '.prproj') {
        const root = makeFolder('root');
        const value = { guid: { toString: () => id }, name: id, path: file, root, saves: 0,
            async save() { this.saves++; return true; },
            async getRootItem() { return root; }, lockedAccess(fn) { fn(); }, executeTransaction(fn) { fn({ addAction(action) { action(); } }); return true; },
            async importFiles(files, suppressUI, bin, numbered) {
                assert.equal(active, this); assert.equal(suppressUI, true); assert.equal(numbered, false);
                imports.push([...files]);
                bin.items.push(...(partial ? files.slice(0, 1) : files).map(makeClip));
                if (partial) { partial = false; throw new Error('injected partial import'); }
                return true;
            } };
        open.set(id, value);
        return value;
    }
    active = project('original'); newProject = project('other');
    const ppro = {
        Project: {
            async getActiveProject() { return active; },
            getProject(guid) { return open.get(guid.toString()) || null; },
            async open(file) { log.push('open ' + file); active = [...open.values()].find(p => p.path === file) || project(file.split('/').pop().replace('.prproj', '') + '-guid', file); return active; },
            async createProject(file) { log.push('create ' + file); files.add(file); active = project(file.split('/').pop().replace('.prproj', '') + '-guid', file); return active; }
        },
        OpenProjectOptions: class { setShowLocateFileDialog() { return this; } setShowWarningDialog() { return this; } setAddToMRUList() { return this; } },
        FolderItem: { cast: value => value.kind === 'folder' ? value : null },
        ClipProjectItem: { cast: value => value.kind === 'clip' ? value : null },
        ProjectItem: { cast: value => value }, TickTime: { createWithSeconds: seconds => ({ seconds }) },
        Markers: { async getMarkers(item) { return { getMarkers: () => item.marks,
            createAddMarkerAction(name, type, start, duration, comments) {
                assert.equal(type, 'Comment'); assert.equal(comments, 'MiniDiT'); markerActions++;
                return () => item.marks.push({ getName: () => name, getStart: () => start });
            } }; } }
    };
    const receiver = createReceiver(ppro, { identity: async file => file.replace('/alias/', '/media/'),
        exists: async file => files.has(file), makeParent: async () => {} });
    const request = { action: 'import', projectID: 'original', handoff: { version: 1, groups: [{ binPath: ['11.10-海边', 'A001'], clips: [
        { path: '/media/A.MP4', canonicalPath: '/media/A.MP4', proxy: '/proxy/A.MP4', canonicalProxyPath: '/proxy/A.MP4', marks: [{ name: 'Shot Mark 1', seconds: 1, duration: .04 }] },
        { path: '/media/B.MP4', canonicalPath: '/media/B.MP4', marks: [] }
    ] }] } };
    return { receiver, request, imports, original: active, other: newProject, makeFolder, files, open, log, ppro,
        get active() { return active; }, switchProject(value) { active = value; }, stats: () => ({ binActions, markerActions }) };
}

test('production receiver resumes partial imports, finds moved media, and preserves user proxies/markers', async () => {
    const f = fixture();
    assert.equal((await f.receiver.identify()).id, 'original');
    const first = await f.receiver.receive(f.request);
    assert.equal(first.imported, 1); assert.deepEqual(first.failedPaths, ['/media/B.MP4']);
    const projectBin = f.original.root.items[0], roll = projectBin.items[0], a = roll.items.pop();
    const moved = f.makeFolder('User moved here'); moved.items.push(a); f.original.root.items.push(moved);
    const second = await f.receiver.receive(f.request);
    assert.equal(second.imported, 1); assert.equal(second.skipped, 1); assert.deepEqual(second.failedPaths, []);
    assert.deepEqual(f.imports, [['/media/A.MP4', '/media/B.MP4'], ['/media/B.MP4']]);
    assert.equal(a.proxy, '/proxy/A.MP4'); assert.equal(f.stats().markerActions, 1);
    assert.equal((await f.receiver.receive(f.request)).imported, 0); assert.equal(f.imports.length, 2);
    a.proxy = '/user/proxy.MP4'; a.marks[0] = { getName: () => 'User marker', getStart: () => ({ seconds: 1 }) };
    const warnings = await f.receiver.receive(f.request);
    assert.equal(a.proxy, '/user/proxy.MP4'); assert.equal(a.marks.length, 1); assert.equal(warnings.warnings.length, 2);
    const aliased = structuredClone(f.request); aliased.handoff.groups[0].clips = [{ ...aliased.handoff.groups[0].clips[0], path: '/alias/A.MP4', canonicalPath: '/media/A.MP4' }];
    assert.equal((await f.receiver.receive(aliased)).skipped, 1); assert.equal(f.imports.length, 2);
    f.switchProject(f.other);
    await assert.rejects(f.receiver.receive(f.request), /项目已切换/); assert.equal(f.other.root.items.length, 0);
    f.switchProject(f.original);
    let checks = 0;
    await assert.rejects(f.receiver.receive(f.request, async () => { if (++checks === 2) f.switchProject(f.other); }), /项目已切换/);
    assert.equal(f.other.root.items.length, 0);
});

test('target project is found by name, opened, or created, and retries only accept the original project', async () => {
    const f = fixture();
    const target = { name: '11.10-海边', path: '/Users/me/Movies/11.10-海边.prproj' };
    const request = structuredClone(f.request); delete request.projectID; request.handoff.project = target;
    // 没有同名项目：新建并保存，片段进新项目，原来打开的项目不受影响。
    const first = await f.receiver.receive(request);
    assert.equal(first.created, true); assert.equal(first.project, '11.10-海边-guid'); assert.deepEqual(f.log, ['create ' + target.path]);
    const created = f.open.get('11.10-海边-guid');
    assert.equal(created.saves, 1); assert.equal(f.original.root.items.length, 0);
    assert.equal(first.imported, 1); assert.deepEqual(first.failedPaths, ['/media/B.MP4']);
    // 用户切回别的项目后再发送：打开已有的同名项目，不再新建；已有片段不重复。
    f.switchProject(f.original);
    const second = await f.receiver.receive({ ...request, projectID: first.projectID });
    assert.equal(second.created, false); assert.deepEqual(f.log, ['create ' + target.path, 'open ' + target.path]);
    assert.equal(second.imported, 1); assert.equal(second.skipped, 1); assert.equal(created.saves, 2);
    // 当前打开的就是目标项目：直接使用。
    assert.equal((await f.receiver.receive(request)).skipped, 2); assert.equal(f.log.length, 2);
    // 导入时切到别的项目不影响写入目标项目；目标项目被关闭则停止。
    f.switchProject(f.original);
    let checks = 0;
    await f.receiver.receive(request, async () => { if (++checks === 2) f.switchProject(f.other); });
    f.switchProject(f.original); checks = 0;
    await assert.rejects(f.receiver.receive(request, async () => { if (++checks === 2) f.open.delete('11.10-海边-guid'); }), /已关闭/);
    // 原项目被删除后重试：不新建；被替换成另一个同名项目：拒绝。
    f.switchProject(f.original); f.files.delete(target.path);
    await assert.rejects(f.receiver.receive({ ...request, projectID: first.projectID }), /未找到原项目/);
    f.files.add(target.path); f.open.delete('11.10-海边-guid');
    const replaced = f.ppro.Project.open; f.ppro.Project.open = async file => { f.switchProject({ ...f.other, path: file }); return f.active; };
    await assert.rejects(f.receiver.receive({ ...request, projectID: first.projectID }), /已非原项目/);
    f.ppro.Project.open = replaced;
    await assert.rejects(f.receiver.receive({ ...request, handoff: { ...request.handoff, project: { name: 'x', path: 'relative.prproj' } } }), /目标项目无效/);
});

test('expired or cancelled attempts cannot reach Premiere', async () => {
    const base = await fs.mkdtemp(path.join(os.tmpdir(), 'minidit-pr-'));
    try {
        await fs.mkdir(base + '/requests');
        const f = fixture(), worker = createMailbox(fs, base, f.receiver);
        const id = '00000000-0000-4000-8000-000000000001', dir = base + '/requests/' + id;
        await fs.mkdir(dir);
        const request = { ...f.request, protocolVersion: 1, id, expiresAt: Date.now()/1000 - 1 };
        await fs.writeFile(dir + '/request.json', JSON.stringify(request));
        await fs.writeFile(dir + '/lease.json', JSON.stringify({ id, expiresAt: Date.now()/1000 + 10 }));
        await worker.tick(); assert.equal(f.imports.length, 0);
        request.expiresAt = Date.now()/1000 + 10;
        await fs.writeFile(dir + '/request.json', JSON.stringify(request));
        await fs.unlink(dir + '/lease.json'); await worker.tick(); assert.equal(f.imports.length, 0);
        // A fresh request is claimed once even with simultaneous polling.
        await fs.writeFile(dir + '/lease.json', JSON.stringify({ id, expiresAt: Date.now()/1000 + 10 }));
        await Promise.all([worker.tick(), worker.tick()]);
        const result = JSON.parse(await fs.readFile(dir + '/result.json', 'utf8'));
        assert.equal(result.id, id); assert.equal(result.value.imported, 1); assert.equal(f.imports.length, 1);
        await worker.tick(); assert.equal(f.imports.length, 1);
        assert.equal(JSON.parse(await fs.readFile(base + '/heartbeat.json', 'utf8')).busy, false);
    } finally { await fs.rm(base, { recursive: true, force: true }); }
});

test('plugin declares a supported host and only filesystem access', async () => {
    const manifest = JSON.parse(await fs.readFile(path.join(__dirname, '../../Apps/MiniDiT/MiniDiT/Resources/PremierePlugin.bundle/manifest.json'), 'utf8'));
    assert.equal(manifest.host.app, 'premierepro'); assert.equal(manifest.host.minVersion, '25.6.0');
    assert.equal(manifest.requiredPermissions.localFileSystem, 'fullAccess'); assert.equal(manifest.requiredPermissions.network, undefined);
});
