"""Exercise production Resolve import code with a deterministic media-pool API.
No installed Resolve project or user library is opened or changed.
"""
import contextlib, io, json, os, pathlib, sys, fcntl, hashlib

script_path, sandbox = map(pathlib.Path, sys.argv[1:3])
os.environ['HOME'] = str(sandbox)
source = script_path.read_text().split('resolve = fs.scriptapp("Resolve")', 1)[1]
source = 'resolve = fs.scriptapp("Resolve")' + source

class Clip:
    def __init__(self, path):
        self.properties = {'File Path': path, 'Start TC': '', 'Drop frame': '0', 'Proxy Media Path': ''}
        self.markers = {}; self.metadata = {}; self.add_calls = 0
    def GetClipProperty(self, key): return self.properties.get(key, '')
    def SetClipProperty(self, key, value): self.properties[key] = value; return True
    def GetMarkers(self): return self.markers
    def AddMarker(self, frame, color, name, note, duration):
        self.add_calls += 1; self.markers[frame] = {'name': name}; return True
    def SetMetadata(self, metadata): self.metadata.update(metadata); return True
    def LinkProxyMedia(self, path): self.properties['Proxy Media Path'] = path; return True

class Folder:
    def __init__(self, name): self.name = name; self.clips = []; self.children = []
    def GetName(self): return self.name
    def GetClipList(self): return self.clips
    def GetSubFolderList(self): return self.children

class Pool:
    def __init__(self): self.root = Folder('root'); self.current = self.root; self.calls = []; self.partial = True
    def GetRootFolder(self): return self.root
    def AddSubFolder(self, root, name): f = Folder(name); root.children.append(f); return f
    def SetCurrentFolder(self, folder): self.current = folder; return True
    def ImportMedia(self, paths):
        self.calls.append(paths.copy())
        imported = [Clip(p) for p in paths[:1] if pathlib.Path(p).exists()] if self.partial else [Clip(p) for p in paths if pathlib.Path(p).exists()]
        self.current.clips.extend(imported)
        if self.partial:
            self.partial = False
            raise RuntimeError('injected partial import')
        return imported

class Project:
    def __init__(self, uid, name=None): self.uid = uid; self.name = name or uid.title(); self.pool = Pool()
    def GetUniqueId(self): return self.uid
    def GetName(self): return self.name
    def GetMediaPool(self): return self.pool
    def GetSetting(self, key): return {'colorScienceMode': 'davinciYRGBColorManaged', 'separateColorSpaceAndGamma': '0'}.get(key, '')
class Library:
    def __init__(self, name, parent=None): self.name = name; self.parent = parent; self.projects = {}; self.folders = {}
    def add(self, name):
        f = Library(name, self); self.folders[name] = f; return f
class Manager:
    """Resolve project library: nested folders, a current folder and a loaded project."""
    def __init__(self):
        self.root = Library('root'); self.folder = self.root
        self.current = Project('original', 'Original'); self.root.projects['Original'] = self.current
        self.switch_at = None; self.reads = 0; self.saved = []; self.created = []
    def GetCurrentProject(self):
        self.reads += 1
        if self.switch_at == self.reads: self.current = Project('switched')
        return self.current
    def GetProjectManager(self): return self
    def GotoRootFolder(self): self.folder = self.root; return True
    def GetProjectListInCurrentFolder(self): return list(self.folder.projects)
    def GetFolderListInCurrentFolder(self): return list(self.folder.folders)
    def OpenFolder(self, name):
        if name not in self.folder.folders: return False
        self.folder = self.folder.folders[name]; return True
    def GotoParentFolder(self):
        if not self.folder.parent: return False
        self.folder = self.folder.parent; return True
    def LoadProject(self, name):
        p = self.folder.projects.get(name)
        if p: self.current = p
        return p
    def CreateProject(self, name):
        if name in self.folder.projects: return None
        p = Project('new-' + name, name); self.folder.projects[name] = p; self.current = p; self.created.append((self.folder.name, name)); return p
    def SaveProject(self): self.saved.append(self.current.GetName()); return True
class Fusion:
    def __init__(self): self.manager = Manager()
    def scriptapp(self, _): return self.manager

fs = Fusion(); manager = fs.manager; original = manager.current; pool = original.pool
media = sandbox / 'resolve-work'; media.mkdir()
a, b, proxy = (media / name for name in ('A.MP4', 'B.MP4', 'A-proxy.MP4'))
for path in (a, b, proxy): path.write_bytes(b'isolated test media')
request = {'action': 'import', 'project': 'Original', 'projectID': 'original', 'color': True, 'events': [{'bin': 'A001', 'clips': [
    {'path': str(a), 'proxy': str(proxy), 'roll': 'A001', 'marks': [{'frame': 12, 'name': 'Shot Mark 1'}], 'timecode': '01:00:00:00', 'gamma': 'S-Log3', 'primaries': 'S-Gamut3.Cine'},
    {'path': str(b), 'proxy': '', 'roll': 'A001', 'marks': [], 'timecode': '', 'gamma': '', 'primaries': ''}]}]}
input_path = sandbox / 'request.json'

def run(payload=request):
    input_path.write_text(json.dumps(payload))
    sys.argv = ['resolve-helper', 'fake.so', str(input_path)]
    scope = dict(fs=fs, json=json, sys=sys, os=os, fcntl=fcntl, hashlib=hashlib)
    output = io.StringIO()
    try:
        with contextlib.redirect_stdout(output): exec(compile(source, 'production-resolve-helper', 'exec'), scope)
        return json.loads(output.getvalue())
    finally:
        if 'lock' in scope: scope['lock'].close()

first = run()
assert first['imported'] == 1 and first['failedPaths'] == [str(b)], first
clip_a = pool.root.children[0].clips.pop()
moved = pool.AddSubFolder(pool.root, 'User moved clips here'); moved.clips.append(clip_a)
second = run()
assert second['imported'] == 1 and second['skipped'] == 1 and second['failedPaths'] == [], second
assert pool.calls == [[str(a), str(b)], [str(b)]], pool.calls
assert clip_a.add_calls == 1 and clip_a.GetClipProperty('Proxy Media Path') == str(proxy)
assert clip_a.metadata['Reel Number'] == 'A001'
assert clip_a.GetClipProperty('Start TC') == '01:00:00:00'
third = run()
assert third['imported'] == 0 and third['skipped'] == 2 and len(pool.calls) == 2, third
# Existing user marker must not be overwritten; warnings can be retried without duplicate media.
clip_a.markers[12]['name'] = 'User note'
warning = run()
assert warning['metadataWarnings'] and clip_a.markers[12]['name'] == 'User note' and clip_a.add_calls == 1
assert len(pool.calls) == 2
# Real filesystem identity handles a path alias without creating duplicate media.
alias = media / 'alias.MP4'; alias.symlink_to(a)
aliased = json.loads(json.dumps(request)); aliased['events'][0]['clips'] = [dict(request['events'][0]['clips'][0], path=str(alias))]
assert run(aliased)['skipped'] == 1 and len(pool.calls) == 2
# A live old helper owns the project lock; another attempt must not import concurrently.
lock_path = sandbox / 'Library/Application Support/MiniDiT/ResolveLocks' / (hashlib.sha256(b'original').hexdigest() + '.lock')
with lock_path.open('a') as held:
    fcntl.flock(held.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    try: run(); raise AssertionError('concurrent send accepted')
    except SystemExit as error: assert error.code == 4
assert len(pool.calls) == 2
# Another project is open: save it, find the target by name in a nested folder and load it there.
shoots = manager.root.add('Shoots').add('2026')
other = Project('other', 'Other'); manager.current = other; manager.saved = []
manager.root.projects.pop('Original'); shoots.projects['Original'] = original
moved_run = run()
assert manager.current is original and manager.saved == ['Other', 'Original'] and moved_run['created'] is False, (manager.saved, moved_run)
assert moved_run['skipped'] == 2 and other.pool.calls == [] and len(pool.calls) == 2
# No project of that name: create it at the library root, import there, and save it.
manager.current = other; manager.saved = []
fresh = dict(request, project='11.11-New Shoot'); fresh.pop('projectID')
created = run(fresh)
new_project = manager.current
assert created['created'] is True and manager.created == [('root', '11.11-New Shoot')] and created['projectID'] == 'new-11.11-New Shoot', created
assert created['imported'] == 1 and new_project.pool.calls == [[str(a), str(b)]] and manager.saved == ['Other', '11.11-New Shoot']
assert other.pool.calls == []
# Sending again finds the project it created instead of making a second one.
again = run(dict(fresh, projectID=created['projectID']))
assert again['created'] is False and len(manager.created) == 1 and len(new_project.pool.calls) == 2
# A retry bound to the original project refuses a same-named replacement or a deleted project.
impostor = Project('recreated', 'Original'); shoots.projects['Original'] = impostor; manager.current = other
try: run(); raise AssertionError('replacement project accepted')
except RuntimeError as error: assert '已非原项目' in str(error)
assert impostor.pool.calls == []
shoots.projects.pop('Original'); manager.current = other
try: run(); raise AssertionError('deleted project recreated on retry')
except RuntimeError as error: assert '未找到原项目' in str(error)
assert len(manager.created) == 1
shoots.projects['Original'] = original
# Switch between helper startup and the guarded import; no media may go to the new project.
manager.current = original; manager.switch_at = manager.reads + 2
try: run(); raise AssertionError('project switch accepted')
except RuntimeError as error: assert '项目已切换' in str(error)
assert manager.current.pool.calls == []
print('PASS: production Resolve script opens the same-named project (saving the open one first, searching nested folders) or creates it at the library root, imports into its media pool and saves it; resumes a partial import, deduplicates moved files/path aliases, preserves markers, repairs metadata/proxy links; a bound retry refuses a replaced, deleted or switched project')
