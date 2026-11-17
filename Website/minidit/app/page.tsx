"use client";

import { useEffect, useRef, useState } from "react";
import ProductDemo from "./components/product-demo";
import { ArrowDown, ArrowUpRight, Check, Film, FileText, Folder, GitFork, Menu, Monitor, Plus, X } from "lucide-react";

const project = "https://github.com/751K/MiniDiT";

function Brand() {
  return <a className="brand" href="#top" aria-label="MiniDiT 首页"><span>MiniDiT</span></a>;
}

function InterfaceFigure({ src, width, height, alt, caption }: {
  src: string; width: number; height: number; alt: string; caption?: string;
}) {
  return <figure className="feature-figure">
    <div className="feature-image-surface"><div className="feature-shot">
      <img src={src} width={width} height={height} alt={alt} loading="lazy" decoding="async" />
    </div></div>
    {caption && <figcaption><span className="feature-caption">{caption}</span></figcaption>}
  </figure>;
}

function VideoWorkflow() {
  return <div className="video-section" id="video">
    <div className="video-copy">
      <h2 id="video-title">原片、代理与时间码<br />一起交给后期</h2>
      <p>MiniDiT 会同时导入视频原片、代理文件及拍摄信息，并对导入文件进行校验。用户可以根据需要启用备份。</p>
      <dl className="capability-list video-capabilities">
        <div><dt>加入同名项目</dt><dd>下载完成后，视频加入与 MiniDiT 项目同名的 DaVinci Resolve 项目、Premiere Pro 项目、Final Cut Pro 资源库或剪映草稿，没有就新建。发送失败时可以重试，无需重新下载。</dd></div>
        <div><dt>时间码与拍摄标记</dt><dd>用户可以逐帧预览视频，也可以使用源时间码或拍摄标记（Shot Mark）定位画面。MiniDiT 会在导入后期软件时保留源时间码和拍摄标记。</dd></div>
        <div><dt>卷号与色彩处理</dt><dd>MiniDiT 会在后期软件中保留片段的卷号。用户还可以让 MiniDiT 根据拍摄信息，自动设置 DaVinci Resolve 的输入色彩空间或 Final Cut Pro 的 Log 处理。</dd></div>
      </dl>
    </div>
    <div className="video-visual">
      <div className="video-still"><img src="images/coast-960.webp" width={960} height={640} alt="视频素材示意，右下角显示源时间码" loading="lazy" /><span className="video-timecode">01:00:18:12</span><div className="video-safe-area" /></div>
      <div className="video-file-tree" aria-label="视频文件组织示例">
        <div className="folder-row"><Folder size={17} /><strong>11.7-海边散步</strong><span>A001</span></div>
        <div className="file-row"><Film size={15} /><span>C0001.MP4</span><small>原片</small><Check size={13} /></div>
        <div className="file-row"><FileText size={18} /><span>C0001M01.XML</span><small>拍摄信息</small><Check size={13} /></div>
        <div className="file-row proxy-row"><Folder size={15} /><span>Proxy / C0001.MP4</span><small>代理</small><Check size={13} /></div>
      </div>
      <p className="video-example-caption">文件组织示例 · 卷号 A001，代理与原片同名关联</p>
    </div>
  </div>;
}

/** 联机拍摄的取景示意：画面、三分线、矢量示波器和相机屏幕式参数条，都是静态示意。 */
function TetherWorkflow() {
  return <div className="video-section tether-section">
    <div className="video-copy">
      <h2 id="tether-title">在 Mac 上取景、对焦<br />拍完直接进项目</h2>
      <p>相机开启遥控拍摄后，MiniDiT 通过 Wi-Fi 或 USB 显示实时取景，并在电脑上调整拍摄参数。每张照片先存入本机的联机缓存，再按当前项目的命名、备份和后期软件设置自动导入。</p>
      <dl className="capability-list video-capabilities">
        <div><dt>拍摄参数</dt><dd>切换拍照、录像、慢快动作和间隔录像，调整快门、光圈、ISO、曝光补偿和白平衡。白平衡可以设置色温、微调偏移，也可以用灰卡取白存入自定义白平衡。</dd></div>
        <div><dt>监看工具</dt><dd>直方图、波形、斑马纹、峰值对焦、伪色、带肤色线的矢量示波器和点测光；取景框线可显示三分线、安全框和画幅遮罩，变形镜头画面可以反挤压显示。</dd></div>
        <div><dt>对焦控制</dt><dd>点按画面对焦，放大检查细节；手动调焦时显示对焦距离，记下 A、B 两个焦点后可以按设定时长平滑拉焦。</dd></div>
      </dl>
      <p className="feature-note">目前支持 Sony α 相机，Wi-Fi 与 USB 遥控拍摄都已在 α7 V 上实机验证。命令行和 MCP 也可以遥控同一窗口。</p>
    </div>
    <div className="video-visual">
      <div className="video-still tether-still">
        <img src="images/coast-960.webp" width={960} height={640} alt="联机取景示意：画面叠加三分线、右上角为矢量示波器，底部为拍摄参数条" loading="lazy" />
        <div className="tether-thirds" aria-hidden="true" />
        <svg className="tether-scope" viewBox="0 0 100 100" aria-hidden="true">
          <circle cx="50" cy="50" r="47" /><line x1="50" y1="3" x2="50" y2="97" /><line x1="3" y1="50" x2="97" y2="50" />
          <line className="skin" x1="50" y1="50" x2="23" y2="11" />
          <ellipse className="trace" cx="45" cy="47" rx="9" ry="5" transform="rotate(-35 45 47)" />
        </svg>
        <span className="tether-focus" aria-hidden="true" />
      </div>
      <div className="tether-bar" aria-label="拍摄参数示意">
        <span>P</span><span>1/250</span><span>F2.8</span><span>ISO 400</span><span>±0.0</span><span>5600K</span>
      </div>
      <p className="video-example-caption">取景示意 · 参数可点按选择，也可以悬停后用滚轮逐档调整</p>
    </div>
  </div>;
}

const photoHandoffs = [
  { title: "Capture One", body: "按项目名新建或接续已有会话，照片直接写入 Capture 文件夹，机内星级一起带入；可按机型自动套用创意外观。" },
  { title: "Lightroom Classic", body: "通过插件加入当前目录，按项目建立收藏夹；RAW + JPG/HIF 自动叠放，保留机内星级。" },
  { title: "导入文件夹", body: "可以只存文件夹，沿用自己的目录规则。导完后用访达、Adobe Bridge 或 DxO PhotoLab 打开；用 DxO 打开时，RAW 会预先写好创意外观设置。" },
];

const questions = [
  ["新建项目时要选什么？", "选择日期、事件名称和项目类型：照片、视频，或照片和视频。导入到这个项目时只取这一类素材；新建项目窗口只显示这一类的保存位置。类型可以之后在项目列表的右键菜单中更改，已导入的文件不受影响。"],
  ["当前支持哪些相机和电脑？", "MiniDiT 面向摄影与视频创作者，当前主要适配 Sony α 相机，已在 α7 V（ILCE-7M5）上实机验证。读卡器还可以导入佳能 EOS（CR3 / CR2 照片，MP4 与 Cinema RAW Light 视频）、富士 RAF、尼康 NEF / NRW 照片，以及大疆 Osmo 等相机的存储卡（.LRF 作为代理）；佳能 EOS、富士 X / GFX、尼康 Z 系列与大疆 Osmo 的无线导入为试验性功能，尚未用真机验证。电脑需要 Apple 芯片和 macOS 14 或更新版本。"],
  ["联机拍摄需要哪些准备，拍下的照片存到哪里？", "在相机上开启遥控拍摄，并让相机与 Mac 连接同一 Wi-Fi，然后在来源页相机的右键菜单中选择“联机拍摄”。Wi-Fi 和 USB 连接都可以（USB 时把相机的 USB 连接方式设为“PC 遥控”）。每张照片先存入本机的联机缓存，再自动导入当前项目，执行项目已设置的命名、备份和后期软件交接；尚未选择项目时照片留在缓存中，选择项目后再补导。"],
  ["拍摄项目和磁盘文件夹怎样对应？", "项目记录同一拍摄任务中的已导入文件，以及它们的实际位置。照片和视频分别选择磁盘、目录规则与后期软件；可以按项目名称、拍摄日期、直接存放或自定义规则建立目录。使用 C1 新建会话时，照片写入该会话的 Capture 文件夹。从项目列表移除项目只移除记录，不删除磁盘文件。"],
  ["Wi-Fi 导过的素材，换读卡器还认得吗？", "两种连接方式共用导入记录，匹配的已导入文件可复用。Wi-Fi 仅导代理时，原片仍记为未导入；之后用读卡器补原片，会沿用原目录与卷号，并核对已有代理和 XML。无线连接需相机与 Mac 处于同一 Wi-Fi，并开启相机的遥控拍摄。"],
  ["“已备份”代表刚刚重新核验了吗？", "素材角标表示当前可访问的副本数量：一份是“已导入”，两份是“已备份”。副本检查通过文件存在和大小判断可访问性，不等于重新比较内容。导入时的内容校验与生成的 ASC MHL 清单，是另一份核验依据。"],
  ["现在支持几处备份，之后怎样复查？", "可以添加多个备份位置，分别启用并选择哪些必须完成；每个位置独立记录进度，一处失败不影响其他位置。导入时使用 xxHash64 核对内容，每个位置分别生成 ASC MHL 清单，可由兼容工具后续复查。读卡器可核对源文件与落盘副本；Wi-Fi 无法取得相机端源文件校验值，按接收内容核对，备份读回比对。缺失的备份可以在项目的导入记录中补齐，无需重新连接原卡。"],
  ["导入前能预览视频和时间码吗？", "可以播放读卡器或已导入的视频，逐帧查看、跳到 Shot Mark，也能输入源时间码定位。Wi-Fi 优先缓存代理；没有代理时，会显示原片大小，由你决定是否缓存。预览缓存不写入导入记录，也不算完成备份。"],
  ["个人创作和团队交接会限制不同功能吗？", "所有功能均可使用。两种工作方式只提供推荐设置，需要你主动应用。项目类型、命名规则、存放位置、自动导入、备份和色彩处理都可自行选择；个人拍摄同样可以使用校验清单，团队任务也可以只取部分素材。"],
  ["连接后期软件需要哪些设置？", "Capture One 需要允许 macOS 自动化控制；Lightroom Classic 需要安装 MiniDiT 插件；DaVinci Resolve 需要把外部脚本使用设为“本地”；Premiere Pro 需要 25.6 或更新版本，并安装 MiniDiT 插件、打开其面板。Final Cut Pro 通过 FCPXML 接收素材。剪映专业版无需设置，但打开过的草稿会被剪映加密，之后需在剪映中手动导入。具体步骤见使用说明。也可以选择只存文件夹。"],
  ["能让 AI 助手操作 MiniDiT 吗？", "可以。MiniDiT 提供命令行工具和 MCP 服务，助手可以查询项目与设备、筛选和选择素材、预览并开始导入，也可以遥控联机拍摄：读写相机设置并回读确认、拍摄、取一帧取景画面或曝光分析数据。两种方式都通过本机接口操作正在运行的应用，普通导入仍需先选择或新建项目。"],
  ["拖到访达和拖到项目，有什么区别？", "拖到桌面或访达文件夹，只复制所选原文件，保留卡上原片，不执行项目导入、备份或后期交接。拖到拍摄项目，则执行正常导入流程，包括已设置的校验、备份、项目记录和后期软件交接。"],
];

/** 每条问题带自己的标题，所以用标题里的按钮，而不是 details。各条可同时展开。
 *  收起的答案设为 hidden="until-found"：浏览器的页内查找能搜到，找到时展开。 */
function FAQList() {
  const [open, setOpen] = useState(() => new Set([0]));
  const listRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    // React 只把 hidden 当布尔值，until-found 要直接写到元素上。
    listRef.current?.querySelectorAll<HTMLElement>("[data-faq-answer]").forEach(answer => {
      if (open.has(Number(answer.dataset.faqAnswer))) answer.removeAttribute("hidden");
      else answer.setAttribute("hidden", "until-found");
    });
  }, [open]);
  useEffect(() => {
    const list = listRef.current;
    if (!list) return;
    const found = (event: Event) => {
      const index = Number((event.target as HTMLElement).dataset.faqAnswer);
      setOpen(current => new Set(current).add(index));
    };
    list.addEventListener("beforematch", found, true);
    return () => list.removeEventListener("beforematch", found, true);
  }, []);
  const toggle = (index: number) => setOpen(current => {
    const next = new Set(current);
    if (!next.delete(index)) next.add(index);
    return next;
  });
  return <div className="faq-list" ref={listRef}>{questions.map(([question, answer], index) => <div className={`faq-item ${open.has(index) ? "open" : ""}`} key={question}>
    <h3><button type="button" aria-expanded={open.has(index)} aria-controls={`faq-answer-${index}`} onClick={() => toggle(index)}>{question}<Plus size={17} /></button></h3>
    <div id={`faq-answer-${index}`} data-faq-answer={index} hidden={!open.has(index)}><p>{answer}</p></div>
  </div>)}</div>;
}

export default function Home() {
  const [menu, setMenu] = useState(false);
  const [narrow, setNarrow] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);
  // 窄屏时导航是原生 popover（点外面、按 Esc 都能关）；宽屏时同一组链接直接排在页眉里。
  useEffect(() => {
    const query = matchMedia("(max-width: 33.75em)");
    const sync = () => setNarrow(query.matches);
    sync();
    query.addEventListener("change", sync);
    return () => query.removeEventListener("change", sync);
  }, []);
  useEffect(() => {
    const list = menuRef.current;
    if (!list) return;
    const toggled = (event: Event) => setMenu((event as ToggleEvent).newState === "open");
    // 放大文字时页眉会变高：打开前按页眉实际底边定位菜单。
    const place = (event: Event) => {
      if ((event as ToggleEvent).newState !== "open") return;
      const bottom = list.closest("header")?.getBoundingClientRect().bottom;
      if (bottom) list.style.setProperty("--header-bottom", `${Math.round(bottom)}px`);
    };
    list.addEventListener("beforetoggle", place);
    list.addEventListener("toggle", toggled);
    return () => { list.removeEventListener("beforetoggle", place); list.removeEventListener("toggle", toggled); };
  }, []);
  const supportsPopover = () => Object.hasOwn(HTMLElement.prototype, "popover");
  // 不支持 popover 的旧浏览器：按钮改为切换 open 类。
  const toggleMenu = () => { if (!supportsPopover()) setMenu(open => !open); };
  const closeMenu = () => {
    if (!narrow) return;
    if (supportsPopover()) menuRef.current?.hidePopover(); else setMenu(false);
  };
  return <div id="top">
    <a className="skip-link" href="#main">跳至正文</a>
    <header className="site-header"><div className="nav-container">
      <Brand />
      <nav aria-label="主导航">
        <div id="site-menu" ref={menuRef} className={menu ? "nav-links open" : "nav-links"} popover={narrow ? "auto" : undefined}>
          <a href="#projects" onClick={closeMenu}>项目管理</a>
          <a href="#backup" onClick={closeMenu}>校验与备份</a>
          <a href="#workflow" onClick={closeMenu}>后期交接</a>
          <a href="#tether" onClick={closeMenu}>联机拍摄</a>
        </div>
      </nav>
      <div className="nav-actions">
        <a className="github-link" href={project} target="_blank" rel="noreferrer" aria-label="在 GitHub 查看 MiniDiT"><GitFork size={19} /></a>
        <a className="button button-small" href="#get">获取 MiniDiT <ArrowUpRight size={13} /></a>
        <button type="button" className="menu-toggle" popoverTarget="site-menu" aria-controls="site-menu" aria-label={menu ? "关闭导航" : "打开导航"} aria-expanded={menu} onClick={toggleMenu}>{menu ? <X size={21} /> : <Menu size={21} />}</button>
      </div>
    </div></header>
    <main id="main">
      <section className="hero container">
        <h1>把时间<br /><span>留给创作</span></h1>
        <p className="hero-description">MiniDiT 是一款 Mac 上的拍摄素材导入与管理工具。<br className="desktop-break" />从相机或读卡器导入照片和视频，按项目整理、检查文件并按需备份，再交给修图和剪辑软件。<br className="desktop-break" />索尼相机还可以通过 Wi-Fi 联机拍摄，拍完直接进入项目。</p>
        <div className="hero-actions">
          <a className="button button-primary" href="#get">获取 MiniDiT <ArrowUpRight size={16} /></a>
          <a className="hero-secondary" href="#demo">查看导入演示 <span><ArrowDown size={14} /></span></a>
        </div>
        <ProductDemo />
      </section>
      <section className="integrations container" aria-label="支持的后期软件">
        <p>继续使用你熟悉的创作工具</p>
        <div className="integration-logos"><span className="integration-capture"><b>C1</b> Capture One</span><span><b className="lr-icon">LrC</b> Lightroom Classic</span><span><i className="resolve-mark"><i /><i /><i /></i> DaVinci Resolve</span><span><b className="lr-icon">Pr</b> Premiere Pro</span><span><i className="fcp-mark" /> Final Cut Pro</span><span><b className="lr-icon">剪</b> 剪映专业版</span></div>
      </section>
      <section className="intro-section container" id="features">
        <div className="section-label"><span>01 — 选择范围与导入</span></div>
        <div className="feature-stories">
          <article className="feature-story wireless-story" aria-labelledby="wireless-title">
            <div className="feature-copy">
              <h2 id="wireless-title">无线随拍随导<br />插卡批量导入</h2>
              <p className="feature-description">MiniDiT 支持 Wi-Fi 无线与有线导入。轻装随拍时连上相机即可取片，正式拍摄后也能通过读卡器集中导入、按项目整理。</p>
            </div>
            <InterfaceFigure src="images/feature-wireless-native-wide.webp" width={1380} height={776} alt="MiniDiT 原生界面截图，使用演示素材展示设备、筛选和新照片列表。" />
          </article>
        </div>
      </section>
      <section className="project-section container" id="projects" aria-labelledby="project-title">
        <div className="section-label"><span>02 — 围绕拍摄任务管理</span></div>
        <div className="feature-story project-story">
          <div className="feature-copy">
            <h2 id="project-title">围绕拍摄任务<br />管理多次导入</h2>
            <p className="feature-description">用户可将不同日期、相机和存储卡中的素材持续导入同一项目，集中管理一项拍摄任务的素材。</p>
            <ul className="project-benefits">
              <li><Check size={17} /><span>下载完成后，MiniDiT 会自动将素材导入目标软件的项目中。</span></li>
              <li><Check size={17} /><span>新建项目时选择照片、视频或两者，导入时只取这一类素材；两类都有时分别显示数量，方便按类型浏览。</span></li>
            </ul>
          </div>
          <InterfaceFigure src="images/feature-project-native.webp" width={1380} height={860} alt="MiniDiT 原生项目界面截图：海边散步项目下有 6 张照片和 2 个视频，右侧展示项目中已导入的文件。使用演示素材。" />
        </div>
        <div className="project-storage-example" aria-label="同一项目的存放位置示例">
          <p><strong>同一个项目，两种存放规则。</strong><span>例如“11.7-海边散步”，照片进入 C1 会话，视频按卷号存到视频盘。</span></p>
          <dl>
            <div><dt>照片</dt><dd>照片盘 / 11.7-海边散步 / Capture</dd></div>
            <div><dt>视频</dt><dd>视频盘 / 11.7-海边散步 / A001</dd></div>
          </dl>
        </div>
      </section>
      <section className="backup-section container" id="backup" aria-labelledby="backup-title">
        <div className="section-label"><span>03 — 校验与备份</span></div>
        <article className="feature-story backup-story">
          <div className="feature-copy">
            <h2 id="backup-title">核对文件内容<br />留下校验记录</h2>
            <p className="feature-description">通过读卡器导入时，MiniDiT 会检查复制后的文件与存储卡上的原文件是否一致。开启备份后，可以添加多个备份位置，软件会逐个读回核对，确认复制无误。</p>
            <dl className="capability-list">
              <div><dt>xxHash64</dt><dd>MiniDiT 使用 xxHash64 算法检查文件在复制前后的内容是否一致。</dd></div>
              <div><dt>ASC MHL 校验清单</dt><dd>MiniDiT 会生成符合 ASC MHL 2.0 标准的校验清单，供支持该格式的软件核验文件完整性。</dd></div>
            </dl>
            <p className="feature-note">原片、代理与 XML 均进入备份和校验清单；每个备份位置分别生成清单。</p>
          </div>
          <InterfaceFigure src="images/feature-backup-native.webp" width={1478} height={776} alt="MiniDiT 原生界面截图，使用演示素材展示当前可访问的副本状态。已备份角标不代表刚刚重新核验。" />
        </article>
      </section>
      <div className="container handoff-sections" id="workflow">
        <section className="workflow-section handoff-section photo-handoff-section" id="photo-handoff" aria-labelledby="photo-handoff-title">
          <div className="section-label"><span>04 — 照片交接</span></div>
          <div className="section-heading"><h2 id="photo-handoff-title">自动导入后期软件</h2><a className="text-link" href={`${project}/blob/main/README.md`} target="_blank" rel="noreferrer">查看软件连接说明 <ArrowUpRight size={15} /></a></div>
          <div className="workflow-grid photo-handoffs">
            {photoHandoffs.map(item => <article className="workflow-step" key={item.title}><h3>{item.title}</h3><p>{item.body}</p></article>)}
          </div>
        </section>
        <section className="handoff-section video-handoff-section" aria-labelledby="video-title">
          <div className="section-label"><span>05 — 视频交接</span></div>
          <VideoWorkflow />
        </section>
      </div>
      <section className="handoff-section video-handoff-section tether-handoff container" id="tether" aria-labelledby="tether-title">
        <div className="section-label"><span>06 — 联机拍摄</span></div>
        <TetherWorkflow />
      </section>
      <section className="faq-section container" id="faq">
        <div><span className="eyebrow">当前版本</span><h2>兼容性与<br />使用边界</h2><a className="text-link" href={`${project}/issues`} target="_blank" rel="noreferrer">反馈问题 <ArrowUpRight size={15} /></a></div>
        <FAQList />
      </section>
      <section className="get-section" id="get"><div className="get-content">
        <div className="get-brand">MiniDiT</div><h2>开始下一次素材导入</h2>
        <p>免费开源 · 当前版本主要适配 Sony α 相机</p>
        <a className="button button-primary" href={`${project}/releases/latest`} target="_blank" rel="noreferrer">下载 MiniDiT <ArrowUpRight size={17} /></a>
        <div className="get-requirements"><Monitor size={13} /> Apple 芯片 · macOS 14 及以上 <span>持续打磨中的早期版本</span></div>
      </div></section>
    </main>
    <footer className="site-footer container">
      <div className="footer-main"><Brand /><div><a href={project} target="_blank" rel="noreferrer">GitHub <ArrowUpRight size={12} /></a><a href={`${project}/blob/main/README.md`} target="_blank" rel="noreferrer">使用说明 <ArrowUpRight size={12} /></a><a href={`${project}/issues`} target="_blank" rel="noreferrer">反馈问题 <ArrowUpRight size={12} /></a></div></div>
      <div className="footer-bottom"><p>© {new Date().getFullYear()} MiniDiT</p><p>Sony / 索尼为索尼集团商标，Canon、FUJIFILM、Nikon、DJI 为各自所有者的商标。MiniDiT 与上述公司均无关联。</p><a href="https://unsplash.com" target="_blank" rel="noreferrer">演示照片来自 Unsplash <ArrowUpRight size={10} /></a></div>
    </footer>
  </div>;
}
