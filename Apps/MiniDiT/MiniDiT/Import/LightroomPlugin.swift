import Foundation

/// Lightroom Classic 插件「MiniDiT.lrplugin」的源码。App 安装插件时把这些文件写到 LrC 的 Modules 文件夹。
///
/// 插件第一次用到时开始运行（LrC 15.6 不理 `LrForceInitPlugin`，App 发唤醒链接触发），后台每秒扫一次任务文件夹：
/// 每个任务（`*.job`）是几张已经下载、校验好的照片，插件用 `catalog:addPhoto` 加进目录（文件留在原处，相当于导入对话框里的「添加」），
/// 放进指定的收藏夹，处理完写一份回执（`*.result`）。App 发 `lightroom://com.kong.minidit/wake` 让它马上处理。
/// 实测（LrC 15.6）：每张约 1.1 秒，和文件大小无关；只生成标准预览。
///
/// 任务文件每行一项，字段用 Tab 分隔：
/// ```
/// minidit-job  1
/// set          MiniDiT            收藏夹集（可省略）
/// collection   10.28-卢森堡        收藏夹（可省略）
/// select       1                  处理完把 LrC 切到这个收藏夹
/// photo        /路径/DSC0001.ARW
/// photo        /路径/DSC0001.HIF   /路径/DSC0001.ARW    第三列：叠到这张 RAW 下面
/// ```
/// 回执每行：`ok|skip|fail <Tab> 路径 [<Tab> 原因]`（skip = 目录里本来就有，只加进收藏夹）。
enum LightroomPlugin {
    /// 改了插件代码就加版本号，App 会提示用户更新。
    static let version = "1.1.2"
    static let toolkitID = "com.kong.minidit"
    static let folderName = "MiniDiT.lrplugin"

    static var files: [String: String] {
        [
            "Info.lua": info,
            "Common.lua": common,
            "Init.lua": initWrapper,
            "Worker.lua": worker,
            "Shutdown.lua": shutdown,
            "URLHandler.lua": urlHandler,
            "ProcessNow.lua": processNow,
            "version.txt": version + "\n",
        ]
    }

    private static var info: String {
        let v = version.split(separator: ".").map { Int($0) ?? 0 } + [0, 0, 0]
        return """
        return {
          LrSdkVersion = 13.0,
          LrSdkMinimumVersion = 10.0,
          LrToolkitIdentifier = '\(toolkitID)',
          LrPluginName = 'MiniDiT',
          LrInitPlugin = 'Init.lua',
          LrForceInitPlugin = true,
          LrShutdownPlugin = 'Shutdown.lua',
          URLHandler = 'URLHandler.lua',
          LrLibraryMenuItems = { { title = '立即处理 MiniDiT 的导入', file = 'ProcessNow.lua' } },
          VERSION = { major = \(v[0]), minor = \(v[1]), revision = \(v[2]), display = '\(version)' },
        }

        """
    }

    private static var common: String {
        """
        local LrPathUtils = import 'LrPathUtils'
        local LrFileUtils = import 'LrFileUtils'
        local LrDate = import 'LrDate'
        local LrApplication = import 'LrApplication'

        local M = {}
        M.version = '\(version)'
        M.base = LrPathUtils.child(LrPathUtils.getStandardFilePath('home'), 'Library/Application Support/MiniDiT/Lightroom')
        M.jobs = LrPathUtils.child(M.base, 'jobs')
        M.results = LrPathUtils.child(M.base, 'results')
        LrFileUtils.createAllDirectories(M.jobs)
        LrFileUtils.createAllDirectories(M.results)

        local logPath = LrPathUtils.child(M.base, 'plugin.log')

        function M.log(s)
          -- 超过 1 MB 就重新开始，免得一直变大。
          local size = LrFileUtils.fileAttributes(logPath)
          if size and size.fileSize and size.fileSize > 1000000 then LrFileUtils.delete(logPath) end
          local f = io.open(logPath, 'a')
          if f then
            f:write(LrDate.timeToUserFormat(LrDate.currentTime(), '%Y-%m-%d %H:%M:%S') .. '  ' .. tostring(s) .. '\\n')
            f:close()
          end
        end

        -- 心跳：App 看这个文件的修改时间判断插件在不在跑，内容里有 LrC 版本、插件版本和当前目录。
        function M.heartbeat()
          local catalog = LrApplication.activeCatalog()
          local tmp = LrPathUtils.child(M.base, 'heartbeat.tmp')
          local f = io.open(tmp, 'w')
          if not f then return end
          f:write('lrc\\t' .. LrApplication.versionString() .. '\\n')
          f:write('plugin\\t' .. M.version .. '\\n')
          f:write('catalog\\t' .. tostring(catalog and catalog:getPath() or '') .. '\\n')
          f:close()
          local dst = LrPathUtils.child(M.base, 'heartbeat')
          if LrFileUtils.exists(dst) then LrFileUtils.delete(dst) end
          LrFileUtils.move(tmp, dst)
        end

        return M

        """
    }

    /// LrC 不报告 Init 里的错误，所以 Init 只是个外壳：用 pcall 加载 Worker，出错写进 /tmp 和插件日志。
    private static let initWrapper = """
    local function note(s)
      local f = io.open('/tmp/minidit-lightroom.log', 'a')
      if f then f:write(os.date('%Y-%m-%d %H:%M:%S') .. '  ' .. s .. '\\n'); f:close() end
    end
    note('Init 开始')
    local ok, err = pcall(function() require 'Worker' end)
    note(ok and 'Init 完成' or ('Init 出错：' .. tostring(err)))

    """

    private static var worker: String {
        """
        local LrTasks = import 'LrTasks'
        local LrFileUtils = import 'LrFileUtils'
        local LrPathUtils = import 'LrPathUtils'
        local LrApplication = import 'LrApplication'
        local C = require 'Common'

        -- 重新加载插件时会再跑一次 Init：用代号让旧的循环自己停下。
        _G.MiniDiT = _G.MiniDiT or {}
        local state = _G.MiniDiT
        state.gen = (state.gen or 0) + 1
        state.running = true
        local my = state.gen

        local function alive() return state.running and state.gen == my end

        local function split(line)
          local t = {}
          for field in (line .. '\\t'):gmatch('([^\\t]*)\\t') do t[#t + 1] = field end
          return t
        end

        local function parse(path)
          local job = { photos = {} }
          for line in io.lines(path) do
            local f = split(line)
            if f[1] == 'set' then job.set = f[2]
            elseif f[1] == 'collection' then job.collection = f[2]
            elseif f[1] == 'select' then job.select = (f[2] == '1')
            elseif f[1] == 'photo' and f[2] and f[2] ~= '' then
              job.photos[#job.photos + 1] = { path = f[2], stackWith = (f[3] and f[3] ~= '') and f[3] or nil,
                                              look = (f[4] and f[4] ~= '') and f[4] or nil }
            end
          end
          return job
        end

        -- 写目录。用户正在操作、别的插件在写时会等不到，重试几次。
        local function write(catalog, name, fn)
          for attempt = 1, 6 do
            local status = catalog:withWriteAccessDo(name, fn, { timeout = 10 })
            if status ~= 'aborted' then return end
            C.log('目录忙，第 ' .. attempt .. ' 次重试')
          end
          error('目录一直被占用')
        end

        local function oneLine(s) return (tostring(s):gsub('[\\t\\r\\n]', ' ')) end

        -- 读 Camera Raw 的 Look 配置文件（XMP），拼成 LrC 修改照片设置用的 Look 表：
        -- 名字、UUID、Supports* 在外层，其余（基础 DCP、RGBTable 和它的数据）放进 Parameters。
        local function readLook(path)
          local f = io.open(path, 'r')
          if not f then return nil end
          local s = f:read('*a'); f:close()
          local name = s:match('<crs:Name>%s*<rdf:Alt>%s*<rdf:li[^>]*>(.-)</rdf:li>')
          if not name then return nil end
          local look = { Name = name, Amount = 1, Parameters = {} }
          local skip = { PresetType = true, Cluster = true, Copyright = true, ContactInfo = true,
                         CameraModelRestriction = true, HasSettings = true }
          for k, v in s:gmatch('crs:([%w_]+)="(.-)"') do
            if k == 'UUID' then look.UUID = v
            elseif k:match('^Supports') then look[k] = (v == 'True')
            elseif not skip[k] then
              if v == 'True' then v = true elseif v == 'False' then v = false end
              look.Parameters[k] = v
            end
          end
          return look
        end

        local function processJob(path)
          local job = parse(path)
          local catalog = LrApplication.activeCatalog()
          local results = {}
          local coll
          if job.collection and job.collection ~= '' then
            write(catalog, 'MiniDiT：建收藏夹', function()
              local parent
              if job.set and job.set ~= '' then parent = catalog:createCollectionSet(job.set, nil, true) end
              coll = catalog:createCollection(job.collection, parent, true)
            end)
          end
          for _, p in ipairs(job.photos) do
            local ok, err = LrTasks.pcall(function()
              local photo = catalog:findPhotoByPath(p.path)
              local status = photo and 'skip' or 'ok'
              write(catalog, 'MiniDiT：添加照片', function()
                if not photo then
                  local raw = p.stackWith and catalog:findPhotoByPath(p.stackWith)
                  if raw then photo = catalog:addPhoto(p.path, raw, 'below') else photo = catalog:addPhoto(p.path) end
                end
                if coll then coll:addPhotos({ photo }) end
              end)
              -- 按创意外观设配置文件（自己装在 Camera Raw 里的「SonyA7M5 Look FL」等）。只给这次新加的照片设，已在目录里的不动。
              if p.look and status == 'ok' then
                local look = readLook(p.look)
                local lok, lerr = LrTasks.pcall(function()
                  if not look then error('读不了 ' .. p.look) end
                  write(catalog, 'MiniDiT：设置配置文件', function()
                    photo:applyDevelopSettings({ CameraProfile = look.Parameters.CameraProfile, Look = look })
                  end)
                end)
                local st = photo:getDevelopSettings() or {}
                local got = type(st.Look) == 'table' and st.Look.Name or nil
                C.log('配置文件 ' .. LrPathUtils.leafName(p.path) .. '：' .. tostring(got)
                      .. ((lok and got == (look and look.Name)) and '' or ('（要 ' .. tostring(look and look.Name) .. '，' .. oneLine(lerr or '未生效') .. '）')))
              end
              results[#results + 1] = status .. '\\t' .. p.path
            end)
            if not ok then
              results[#results + 1] = 'fail\\t' .. p.path .. '\\t' .. oneLine(err)
              C.log('添加失败 ' .. p.path .. '：' .. oneLine(err))
            end
          end
          if coll and job.select then catalog:setActiveSources({ coll }) end

          local name = LrPathUtils.leafName(path):gsub('%.job$', '')
          local tmp = LrPathUtils.child(C.results, name .. '.tmp')
          local f = io.open(tmp, 'w')
          if f then f:write(table.concat(results, '\\n') .. '\\n'); f:close() end
          LrFileUtils.move(tmp, LrPathUtils.child(C.results, name .. '.result'))
          LrFileUtils.delete(path)
        end

        LrTasks.startAsyncTask(function()
          C.log('启动：Lightroom Classic ' .. LrApplication.versionString() .. '，MiniDiT 插件 ' .. C.version)
          while alive() do
            C.heartbeat()
            local names = {}
            for e in LrFileUtils.files(C.jobs) do
              if e:match('%.job$') then names[#names + 1] = e end
            end
            table.sort(names)
            for _, e in ipairs(names) do
              if not alive() then break end
              local ok, err = LrTasks.pcall(processJob, e)
              if not ok then
                C.log('任务出错 ' .. LrPathUtils.leafName(e) .. '：' .. oneLine(err))
                local failed = LrPathUtils.child(C.results, (LrPathUtils.leafName(e):gsub('%.job$', '.failed')))
                if LrFileUtils.exists(e) then LrFileUtils.move(e, failed) end
              end
              C.heartbeat()
            end
            for _ = 1, 10 do
              if state.wake or not alive() then break end
              LrTasks.sleep(0.1)
            end
            state.wake = false
          end
          C.log('停止（代号 ' .. my .. '）')
        end)

        """
    }

    private static let shutdown = """
    if _G.MiniDiT then _G.MiniDiT.running = false end

    """

    private static let urlHandler = """
    return {
      URLHandler = function(url)
        _G.MiniDiT = _G.MiniDiT or {}
        _G.MiniDiT.wake = true
      end,
    }

    """

    private static let processNow = """
    _G.MiniDiT = _G.MiniDiT or {}
    _G.MiniDiT.wake = true

    """
}
