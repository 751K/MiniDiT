const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises'), os = require('node:os'), path = require('node:path');
const { createReceiver } = require('../../Apps/MiniDiT/MiniDiT/Resources/PremierePlugin.bundle/receiver.js');
const { createMailbox } = require('../../Apps/MiniDiT/MiniDiT/Resources/PremierePlugin.bundle/mailbox.js');
function fixture() {
    let active, imports = [], partial = true, binActions = 0, markerActions = 0, newProject;
    const makeFolder = name => ({ kind: 'folder', name, items: [], async getItems() { return this.items; }, createBinAction(name) {
        binActions++; return () => this.items.push(makeFolder(name));
    } });
    const makeClip = file => ({ kind: 'clip', path: file, proxy: '', marks: [], async isSequence() { return false; },
        async isOffline() { return false; }, async getMediaFilePath() { return this.path; }, async canProxy() { return true; },
        async getProxyPath() { return this.proxy; }, async attachProxy(proxy, hiRes) { assert.equal(hiRes, false); this.proxy = proxy; return true; } });
    function project(id) {
        const root = makeFolder('root');
        return { guid: { toString: () => id }, name: id, path: '/' + id + '.prproj', root,
            async getRootItem() { return root; }, lockedAccess(fn) { fn(); }, executeTransaction(fn) { fn({ addAction(action) { action(); } }); return true; },
            async importFiles(files, suppressUI, bin, numbered) {
                assert.equal(active, this); assert.equal(suppressUI, true); assert.equal(numbered, false);
                imports.push([...files]);
                bin.items.push(...(partial ? files.slice(0, 1) : files).map(makeClip));
                if (partial) { partial = false; throw new Error('injected partial import'); }
                return true;
            } };
    }
    active = project('original'); newProject = project('other');
    const ppro = {
        Project: { async getActiveProject() { return active; } },
        FolderItem: { cast: value => value.kind === 'folder' ? value : null },
        ClipProjectItem: { cast: value => value.kind === 'clip' ? value : null },
        ProjectItem: { cast: value => value }, TickTime: { createWithSeconds: seconds => ({ seconds }) },
        Markers: { async getMarkers(item) { return { getMarkers: () => item.marks,
            createAddMarkerAction(name, type, start, duration, comments) {
                assert.equal(type, 'Comment'); assert.equal(comments, 'MiniDiT'); markerActions++;
                return () => item.marks.push({ getName: () => name, getStart: () => start });
            } }; } }
    };
    const receiver = createReceiver(ppro, { identity: async file => file.replace('/alias/', '/media/') });
    const request = { action: 'import', projectID: 'original', handoff: { version: 1, groups: [{ binPath: ['11.10-海边', 'A001'], clips: [
        { path: '/media/A.MP4', canonicalPath: '/media/A.MP4', proxy: '/proxy/A.MP4', canonicalProxyPath: '/proxy/A.MP4', marks: [{ name: 'Shot Mark 1', seconds: 1, duration: .04 }] },
        { path: '/media/B.MP4', canonicalPath: '/media/B.MP4', marks: [] }
    ] }] } };
    return { receiver, request, imports, original: active, other: newProject, makeFolder,
        switchProject(value) { active = value; }, stats: () => ({ binActions, markerActions }) };
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
