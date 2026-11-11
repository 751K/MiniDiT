"use client";

import { useState } from "react";
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
        <div><dt>时间码与拍摄标记</dt><dd>用户可以逐帧预览视频，也可以使用源时间码或拍摄标记（Shot Mark）定位画面。MiniDiT 会在导入后期软件时保留源时间码和拍摄标记。</dd></div>
        <div><dt>卷号与色彩处理</dt><dd>MiniDiT 会在后期软件中保留片段的卷号。用户还可以让 MiniDiT 根据拍摄信息，自动设置 DaVinci Resolve 的输入色彩空间或 Final Cut Pro 的 Log 处理。</dd></div>
      </dl>
    </div>
    <div className="video-visual">
      <div className="video-still"><img src="images/coast.jpg" alt="视频素材示意，右下角显示源时间码" loading="lazy" /><span className="video-timecode">01:00:18:12</span><div className="video-safe-area" /></div>
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

const photoHandoffs = [
  { title: "Capture One", body: "按项目名新建或接续已有会话，照片直接写入 Capture 文件夹，机内星级一起带入。" },
  { title: "Lightroom Classic", body: "通过插件加入当前目录，按项目建立收藏夹；RAW + JPG/HIF 自动叠放，保留机内星级。" },
  { title: "导入文件夹", body: "可以只存文件夹，沿用自己的目录规则。导完后用访达、Adobe Bridge 或 DxO PhotoLab 打开。" },
];

const questions = [
  ["当前支持哪些相机和电脑？", "MiniDiT 面向摄影与视频创作者。当前版本仅适配 Sony α 相机，已在 α7 V（ILCE-7M5）上实机验证，其他品牌尚未适配。电脑需要 Apple 芯片和 macOS 14 或更新版本。"],
  ["拍摄项目和磁盘文件夹怎样对应？", "项目记录同一拍摄任务中的已导入文件，以及它们的实际位置。照片和视频分别选择磁盘、目录规则与后期软件；可以按项目名称、拍摄日期、直接存放或自定义规则建立目录。使用 C1 新建会话时，照片写入该会话的 Capture 文件夹。从项目列表移除项目只移除记录，不删除磁盘文件。"],
  ["Wi-Fi 导过的素材，换读卡器还认得吗？", "两种连接方式共用导入记录，匹配的已导入文件可复用。Wi-Fi 仅导代理时，原片仍记为未导入；之后用读卡器补原片，会沿用原目录与卷号，并核对已有代理和 XML。无线连接需相机与 Mac 处于同一 Wi-Fi，并开启相机的遥控拍摄。"],
  ["“已备份”代表刚刚重新核验了吗？", "素材角标表示当前可访问的副本数量：一份是“已导入”，两份是“已备份”。副本检查通过文件存在和大小判断可访问性，不等于重新比较内容。导入时的内容校验与生成的 ASC MHL 清单，是另一份核验依据。"],
  ["现在支持几处备份，之后怎样复查？", "当前支持工作副本和一处备份。导入时使用 xxHash64 核对内容，ASC MHL 清单可由兼容工具后续复查。读卡器可核对源文件与落盘副本；Wi-Fi 无法取得相机端源文件校验值，首份下载核对大小并计算本地校验值，备份读回比对。多个备份目的地和应用内独立离线复核尚未提供。"],
  ["导入前能预览视频和时间码吗？", "可以播放读卡器或已导入的视频，逐帧查看、跳到 Shot Mark，也能输入源时间码定位。Wi-Fi 优先缓存代理；没有代理时，会显示原片大小，由你决定是否缓存。预览缓存不写入导入记录，也不算完成备份。"],
  ["个人创作和团队交接会限制不同功能吗？", "所有功能均可使用。两种工作方式只提供推荐设置，需要你主动应用。导入范围、命名规则、存放位置、自动导入、备份和色彩处理都可自行选择；个人拍摄同样可以使用校验清单，团队任务也可以只取部分素材。"],
  ["连接后期软件需要哪些设置？", "Capture One 需要允许 macOS 自动化控制；Lightroom Classic 需要安装 MiniDiT 插件；DaVinci Resolve 需要把外部脚本使用设为“本地”。Final Cut Pro 通过生成的 FCPXML 接收素材。具体步骤见使用说明。也可以选择只存文件夹。"],
  ["拖到访达和拖到项目，有什么区别？", "拖到桌面或访达文件夹，只复制所选原文件，保留卡上原片，不执行项目导入、备份或后期交接。拖到拍摄项目，则执行正常导入流程，包括已设置的校验、备份、项目记录和后期软件交接。"],
];

export default function Home() {
  const [menu, setMenu] = useState(false);
  const [faq, setFaq] = useState<number | null>(0);
  return <div id="top">
    <a className="skip-link" href="#main">跳至正文</a>
    <header className="site-header"><div className="nav-container">
      <Brand />
      <nav className={menu ? "nav-links open" : "nav-links"} aria-label="主导航">
        <a href="#projects" onClick={() => setMenu(false)}>项目管理</a>
        <a href="#backup" onClick={() => setMenu(false)}>校验与备份</a>
        <a href="#workflow" onClick={() => setMenu(false)}>后期交接</a>
      </nav>
      <div className="nav-actions">
        <a className="github-link" href={project} target="_blank" rel="noreferrer" aria-label="在 GitHub 查看 MiniDiT"><GitFork size={19} /></a>
        <a className="button button-small" href="#get">获取 MiniDiT <ArrowUpRight size={13} /></a>
        <button className="menu-toggle" aria-label={menu ? "关闭导航" : "打开导航"} aria-expanded={menu} onClick={() => setMenu(!menu)}>{menu ? <X size={21} /> : <Menu size={21} />}</button>
      </div>
    </div></header>
    <main id="main">
      <section className="hero container">
        <h1>把时间<br /><span>留给创作</span></h1>
        <p className="hero-description">MiniDiT 是一款 Mac 上的拍摄素材导入与管理工具。<br className="desktop-break" />从相机或读卡器导入照片和视频，按项目整理、检查文件并按需备份，再交给修图和剪辑软件。</p>
        <div className="hero-actions">
          <a className="button button-primary" href="#get">获取 MiniDiT <ArrowUpRight size={16} /></a>
          <a className="hero-secondary" href="#demo">查看导入演示 <span><ArrowDown size={14} /></span></a>
        </div>
        <ProductDemo />
      </section>
      <section className="integrations container" aria-label="支持的后期软件">
        <p>继续使用你熟悉的创作工具</p>
        <div className="integration-logos"><span className="integration-capture"><b>C1</b> Capture One</span><span><b className="lr-icon">LrC</b> Lightroom Classic</span><span><i className="resolve-mark"><i /><i /><i /></i> DaVinci Resolve</span><span><i className="fcp-mark" /> Final Cut Pro</span></div>
      </section>
      <section className="intro-section container" id="features">
        <div className="section-label"><span>01 — 选择范围与导入</span></div>
        <div className="feature-stories">
          <article className="feature-story wireless-story" aria-labelledby="wireless-title">
            <div className="feature-copy">
              <h3 id="wireless-title">无线随拍随导<br />插卡批量导入</h3>
              <p className="feature-description">MiniDiT 支持 Wi-Fi 无线与有线导入。轻装随拍时连上相机即可取片，正式拍摄后也能通过读卡器集中导入、按项目整理。</p>
            </div>
            <InterfaceFigure src="images/feature-wireless-native-wide.png" width={1380} height={776} alt="MiniDiT 原生界面截图，使用演示素材展示设备、筛选和新照片列表。" />
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
              <li><Check size={17} /><span>项目同时包含照片和视频时，MiniDiT 会显示分类及数量，方便用户按类型浏览素材。</span></li>
            </ul>
          </div>
          <InterfaceFigure src="images/feature-project-native.png" width={1380} height={860} alt="MiniDiT 原生项目界面截图：海边散步项目下有 6 张照片和 2 个视频，右侧展示项目中已导入的文件。使用演示素材。" />
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
            <p className="feature-description">通过读卡器导入时，MiniDiT 会检查复制后的文件与存储卡上的原文件是否一致。开启备份后，软件还会检查备份文件，确认复制无误。</p>
            <dl className="capability-list">
              <div><dt>xxHash64</dt><dd>MiniDiT 使用 xxHash64 算法检查文件在复制前后的内容是否一致。</dd></div>
              <div><dt>ASC MHL 校验清单</dt><dd>MiniDiT 会生成符合 ASC MHL 2.0 标准的校验清单，供支持该格式的软件核验文件完整性。</dd></div>
            </dl>
            <p className="feature-note">原片、代理与 XML 均进入备份和校验清单。</p>
          </div>
          <InterfaceFigure src="images/feature-backup-native.png" width={1478} height={776} alt="MiniDiT 原生界面截图，使用演示素材展示当前可访问的副本状态。已备份角标不代表刚刚重新核验。" />
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
      <section className="faq-section container" id="faq">
        <div><span className="eyebrow">当前版本</span><h2>兼容性与<br />使用边界</h2><a className="text-link" href={`${project}/issues`} target="_blank" rel="noreferrer">反馈问题 <ArrowUpRight size={15} /></a></div>
        <div className="faq-list">{questions.map(([question, answer], index) => <div className={`faq-item ${faq === index ? "open" : ""}`} key={question}>
          <h3><button id={`faq-button-${index}`} aria-expanded={faq === index} aria-controls={`faq-answer-${index}`} onClick={() => setFaq(faq === index ? null : index)}>{question}<Plus size={17} /></button></h3>
          <div id={`faq-answer-${index}`} role="region" aria-labelledby={`faq-button-${index}`} hidden={faq !== index}><p>{answer}</p></div>
        </div>)}</div>
      </section>
      <section className="get-section" id="get"><div className="get-content">
        <div className="get-brand">MiniDiT</div><h2>开始下一次素材导入</h2>
        <p>免费开源 · 当前版本适配 Sony α 相机</p>
        <a className="button button-primary" href={project} target="_blank" rel="noreferrer">在 GitHub 获取 MiniDiT <ArrowUpRight size={17} /></a>
        <div className="get-requirements"><Monitor size={13} /> Apple 芯片 · macOS 14 及以上 <span>持续打磨中的早期版本</span></div>
      </div></section>
    </main>
    <footer className="site-footer container">
      <div className="footer-main"><Brand /><div><a href={project} target="_blank" rel="noreferrer">GitHub <ArrowUpRight size={12} /></a><a href={`${project}/blob/main/README.md`} target="_blank" rel="noreferrer">使用说明 <ArrowUpRight size={12} /></a><a href={`${project}/issues`} target="_blank" rel="noreferrer">反馈问题 <ArrowUpRight size={12} /></a></div></div>
      <div className="footer-bottom"><p>© {new Date().getFullYear()} MiniDiT</p><p>Sony / 索尼为索尼集团商标。MiniDiT 与索尼集团无关联。</p><a href="https://unsplash.com" target="_blank" rel="noreferrer">演示照片来自 Unsplash <ArrowUpRight size={10} /></a></div>
    </footer>
  </div>;
}
