"use client";

import { useEffect, useRef, useState, type CSSProperties } from "react";
import { Camera, Check, ChevronRight, Folder, HardDrive, Image as ImageIcon, Moon, MoreHorizontal, MousePointer2, Plus, RefreshCw, Search, SlidersHorizontal, Sun, Tag, X } from "lucide-react";
import styles from "./product-demo.module.css";
import GlassHighlights from "./glass-highlights";

const demoShots = [
  { image: "coast", name: "DSC00421", kind: "RAW+JPG", capturedAt: "16:24", duration: "", position: "50% 55%", video: false, raw: true, photo: true, size: 36 },
  { image: "cliffs", name: "DSC00422", kind: "RAW+JPG", capturedAt: "16:25", duration: "", position: "50% 50%", video: false, raw: true, photo: true, size: 42 },
  { image: "rocks", name: "DSC00423", kind: "RAW", capturedAt: "16:27", duration: "", position: "50% 60%", video: false, raw: true, photo: false, size: 38 },
  { image: "city", name: "DSC00424", kind: "JPG", capturedAt: "16:32", duration: "", position: "50% 70%", video: false, raw: false, photo: true, size: 8 },
  { image: "walk", name: "DSC00425", kind: "RAW+JPG", capturedAt: "16:36", duration: "", position: "50% 50%", video: false, raw: true, photo: true, size: 35 },
  { image: "street", name: "DSC00426", kind: "RAW", capturedAt: "16:40", duration: "", position: "50% 60%", video: false, raw: true, photo: false, size: 39 },
  { image: "coast", name: "C0001", kind: "S-Log3 · 25p", capturedAt: "16:44", duration: "00:18", position: "35% 75%", video: true, raw: false, photo: false, size: 120 },
  { image: "cliffs", name: "C0002", kind: "4K · 25p", capturedAt: "16:46", duration: "00:12", position: "70% 20%", video: true, raw: false, photo: false, size: 90 },
  { image: "city", name: "C0003", kind: "4K · 25p", capturedAt: "16:49", duration: "00:12", position: "50% 50%", video: true, raw: false, photo: false, size: 95 },
];


const shots = [...demoShots.map(shot => ({...shot, day: "11.7"})),
  {...demoShots[1], name: "DSC00312", day: "11.6"},
  {...demoShots[3], name: "DSC00313", day: "11.6"},
  {...demoShots[7], name: "C0008", day: "11.6"},
  {...demoShots[5], name: "DSC00204", day: "11.2"}];
const projectNames = ["11.7-海边散步", "11.6-城市漫游"];
// 项目类型在新建项目时选择，导入范围跟着当前项目走。
const projectTypes: MediaScope[] = ["all", "all"];
const scopeTitles: Record<MediaScope, string> = { all: "照片和视频", photos: "照片", videos: "视频" };
const dates = [{id:"11.7",label:"11月7日",weekday:"周六"},{id:"11.6",label:"11月6日",weekday:"周五"},{id:"11.2",label:"11月2日",weekday:"周一"}];
type MediaScope = "all" | "photos" | "videos";
function countText(ids: number[]) {
  const videos = ids.filter(id => shots[id].video).length;
  return [ids.length > videos ? `${ids.length - videos} 张照片` : "", videos ? `${videos} 个片段` : ""].filter(Boolean).join(" · ");
}


function SegmentControl<T extends string | number>({ options, value, label, disabled, onChange }: {
  options: readonly { value: T; label: string }[];
  value: T;
  label: string;
  disabled: boolean;
  onChange(value: T): void;
}) {
  const index = Math.max(0, options.findIndex(option => option.value === value));
  return <div className={styles.segmentGroup} role="group" aria-label={label} aria-disabled={disabled}
    style={{ "--segment-count": options.length, "--segment-index": index } as CSSProperties}>
    <span className={styles.segmentThumb} aria-hidden="true" />
    {options.map((option, optionIndex) => <button key={option.value} className={value === option.value ? styles.segmentOn : ""}
      aria-pressed={value === option.value} disabled={disabled} onClick={() => onChange(option.value)}
      onKeyDown={event => {
        const next = event.key === "ArrowLeft" ? (optionIndex + options.length - 1) % options.length
          : event.key === "ArrowRight" ? (optionIndex + 1) % options.length
          : event.key === "Home" ? 0 : event.key === "End" ? options.length - 1 : -1;
        if (next < 0) return;
        event.preventDefault();
        const group = event.currentTarget.parentElement;
        onChange(options[next].value);
        group?.querySelectorAll("button")[next]?.focus();
      }}>{option.label}</button>)}
  </div>;
}

export default function ProductDemo() {
  const [dark,setDark] = useState(true);
  const [query,setQuery] = useState("");
  const [mark,setMark] = useState("all");
  const [refreshed,setRefreshed] = useState(false);
  const [source,setSource] = useState<"wifi"|"card">("wifi");
  const [sourcesOpen,setSourcesOpen] = useState(false);
  const [slot,setSlot] = useState(0);
  const [onlyNew,setOnlyNew] = useState(false);
  const [types,setTypes] = useState({raw:true,photo:true});
  const [thumbSize,setThumbSize] = useState(170);
  const [day,setDay] = useState("11.7");
  const [activeProject,setActiveProject] = useState(0);
  const [projectView,setProjectView] = useState<MediaScope|null>(null);
  const [projectFiles,setProjectFiles] = useState([new Set<number>(),new Set([9,10,11])]);
  const [selected,setSelected] = useState(new Set([0,1,4]));
  const [copied,setCopied] = useState(new Set([9,10,11]));
  const [backedCopies,setBackedCopies] = useState(new Set([9,10,11]));
  const [proxyCopies,setProxyCopies] = useState(new Set<number>());
  const [preview,setPreview] = useState<number|null>(null);
  const [backup,setBackup] = useState(true);
  const [proxy,setProxy] = useState(false);
  const [optionsOpen,setOptionsOpen] = useState(false);
  const [pathsOpen,setPathsOpen] = useState(false);
  const [offline,setOffline] = useState(false);
  const [importing,setImporting] = useState(false);
  const [batch,setBatch] = useState<{ids:number[]; project:number; backup:boolean; proxies:number[]}|null>(null);
  const [result,setResult] = useState<string|null>(null);
  const lightboxRef = useRef<HTMLDialogElement>(null);
  const dropRef = useRef<HTMLButtonElement|null>(null);
  const importBarRef = useRef<HTMLDivElement>(null);

  const scope=projectTypes[activeProject];
  function matches(id:number) {
    const shot=shots[id];
    if (id===8&&!refreshed) return false;
    if (scope==="photos"&&shot.video||scope==="videos"&&!shot.video) return false;
    if (!shot.video&&!((shot.raw&&types.raw)||(shot.photo&&types.photo))) return false;
    if (onlyNew&&copied.has(id)) return false;
    if (source==="wifi"&&slot!==0&&(id%2+1)!==slot) return false;
    if (!query.trim().toLowerCase().split(/\s+/).every(word=>`${shot.name} ${source==="wifi"?"α7 V Wi-Fi":"SDXC 读卡器"}`.toLowerCase().includes(word))) return false;
    const rating=id===0?4:id===4?3:0;
    if (mark==="marked"&&rating===0&&id!==6||mark==="shot"&&id!==6||mark==="rejected") return false;
    if (mark.startsWith("stars:")&&rating<Number(mark.slice(6))) return false;
    return true;
  }
  const filtered=shots.flatMap((_,id)=>matches(id)?[id]:[]);
  const visible=projectView!==null?[...projectFiles[activeProject]].filter(id=>(projectView!=="photos"||!shots[id].video)&&(projectView!=="videos"||shots[id].video))
    :filtered.filter(id=>shots[id].day===day);
  const visibleKey=visible.join(",");
  // 可见范围变了：去掉看不到的选择（导入中不动）。在渲染时调整，不用 effect 再渲染一遍。
  const [prunedKey,setPrunedKey]=useState(visibleKey);
  if(!importing&&prunedKey!==visibleKey){
    setPrunedKey(visibleKey);
    const shown=new Set(visible);
    if([...selected].some(id=>!shown.has(id))) setSelected(new Set([...selected].filter(id=>shown.has(id))));
  }
  const picked=[...selected].filter(id=>visible.includes(id));
  const pickedSize=picked.reduce((n,id)=>n+shots[id].size,0);
  const fresh=visible.filter(id=>!copied.has(id));
  const allPicked=visible.length>0&&visible.every(id=>selected.has(id));
  const selectedVideo=source==="wifi"&&picked.some(id=>shots[id].video);
  const fileCount=picked.reduce((n,id)=>n+(shots[id].raw&&shots[id].photo&&types.raw&&types.photo?2:1),0);
  const scopeFiltered=query!==""||mark!=="all"||onlyNew||!types.raw||!types.photo;

  useEffect(()=>{
    if(!importing||!batch) return;
    const timer=setTimeout(()=>{
      const originals=batch.ids.filter(id=>!batch.proxies.includes(id));
      setCopied(current=>new Set([...current,...originals]));
      if(batch.backup) setBackedCopies(current=>new Set([...current,...originals]));
      setProxyCopies(current=>new Set([...current,...batch.proxies]));
      setProjectFiles(current=>current.map((files,index)=>index===batch.project?new Set([...files,...batch.ids]):files));
      setSelected(new Set());setImporting(false);
      setResult(`${projectNames[batch.project]} · ${batch.proxies.length?`${batch.proxies.length} 个片段仅导代理 · `:""}${batch.backup?"同时保存第二份副本":"仅存储一份"}`);
    },1400);
    return()=>clearTimeout(timer);
  },[importing,batch]);

  // 原生模态框：焦点限制、Esc 关闭、关闭后焦点回到缩略图都由浏览器处理。
  useEffect(()=>{
    const dialog=lightboxRef.current;
    if(preview!==null&&dialog&&!dialog.open){dialog.showModal();dialog.querySelector("button")?.focus();}
  },[preview]);
  useEffect(()=>{
    const close=(event:KeyboardEvent)=>{if(event.key==="Escape"){setOptionsOpen(false);setSourcesOpen(false);setPathsOpen(false);}};
    window.addEventListener("keydown",close);return()=>window.removeEventListener("keydown",close);
  },[]);
  function toggle(id:number){if(importing)return;setSelected(current=>{const next=new Set(current);if(next.has(id))next.delete(id);else next.add(id);return next;});setResult(null);}
  function selectDay(){if(importing)return;setSelected(current=>{const next=new Set(current);visible.forEach(id=>allPicked?next.delete(id):next.add(id));return next;});setResult(null);}
  function chooseDate(value:string){setDay(value);setProjectView(null);setResult(null);setSelected(new Set(filtered.filter(id=>shots[id].day===value&&!copied.has(id))));}
  function beginImport(project=activeProject,ids=picked){
    if(importing||offline||!ids.length||projectView!==null)return;
    setActiveProject(project);setBatch({ids:[...ids],project,backup,proxies:proxy&&source==="wifi"?ids.filter(id=>shots[id].video):[]});
    setImporting(true);setResult(null);setOptionsOpen(false);setPathsOpen(false);
  }
  function badge(id:number){const shot=shots[id];const showRaw=projectView!==null||types.raw,showPhoto=projectView!==null||types.photo;return shot.video?`视频 ${shot.duration}`:[shot.raw&&showRaw?"RAW":"",shot.photo&&showPhoto?"JPG":""].filter(Boolean).join("+");}
  function clearFilters(){setQuery("");setMark("all");setOnlyNew(false);setTypes({raw:true,photo:true});}

  return <>
    <figure className={styles.figure}>
      <div className={styles.demoHeading}><span>交互演示</span><div role="group" aria-label="演示界面外观"><button aria-label="浅色界面" aria-pressed={!dark} onClick={()=>setDark(false)}><Sun/></button><button aria-label="深色界面" aria-pressed={dark} onClick={()=>setDark(true)}><Moon/></button></div></div>
      <div className={styles.stage} id="demo">
        <div className={styles.windowScroll}>
          <div className={`${styles.window} ${dark?styles.dark:""}`} data-testid="product-demo">
            <aside className={styles.projects} aria-label="演示拍摄项目">
              <div className={styles.windowControls} aria-hidden="true"><i/><i/><i/></div>
              <div className={`${styles.panelHeading} ${styles.panelTitle}`}>拍摄项目</div>
              {projectNames.map((name,index)=>{
                const files=[...projectFiles[index]],photos=files.filter(id=>!shots[id].video),videos=files.filter(id=>shots[id].video);
                return <div className={styles.projectGroup} key={name}>
                  <div className={`${styles.projectRow} ${activeProject===index?styles.projectOn:""}`}>
                    <button ref={index===0?dropRef:undefined} aria-pressed={activeProject===index} disabled={importing} onClick={()=>{setActiveProject(index);setProjectView(null);setResult(null);}} onDoubleClick={()=>{setActiveProject(index);setProjectView("all");setSelected(new Set());}} onDragOver={event=>{if(!importing&&!offline&&projectView===null){event.preventDefault();event.dataTransfer.dropEffect="copy";}}} onDrop={event=>{event.preventDefault();if(event.dataTransfer.getData("application/x-minidit-demo")==="selection")beginImport(index);}}><span>{name}</span><small>{files.length}</small></button>
                    <button aria-label={`查看${name}已导入素材`} disabled={importing} onClick={()=>{setActiveProject(index);setProjectView("all");setSelected(new Set());}}><ChevronRight/></button>
                  </div>
                  {photos.length>0&&videos.length>0&&<div className={styles.projectMedia}>{([['photos','照片',photos.length],['videos','视频',videos.length]] as const).map(([value,label,count])=><button key={value} aria-pressed={activeProject===index&&projectView===value} disabled={importing} onClick={()=>{setActiveProject(index);setProjectView(value);setSelected(new Set());}}><span>{label}</span><small>{count}</small></button>)}</div>}
                </div>;
              })}
              <div className={styles.settingsLabel}><SlidersHorizontal/>设置</div>
            </aside>

            <aside className={styles.controls} aria-label="演示设备与筛选">
              <div className={styles.sourceGroup}>
                <div className={styles.panelHeading}><span>设备</span><button aria-label="重新读取演示素材" title="重新读取：发现一个新片段" onClick={()=>setRefreshed(true)} disabled={importing}><RefreshCw/></button><button aria-label="添加或切换演示设备" aria-expanded={sourcesOpen} onClick={()=>setSourcesOpen(!sourcesOpen)} disabled={importing}><Plus/></button></div>
                <button className={styles.deviceRow} onClick={()=>setProjectView(null)}><span className={styles.sourceIcon}>{source==="wifi"?<Camera/>:<HardDrive/>}</span><span className={styles.sourceText}><strong>{source==="wifi"?"α7 V":"SDXC"}</strong><span>{offline?"已断开，保留当前选择":source==="wifi"?"已连接 · Wi-Fi":"读卡器 · SDXC"}</span></span><small>{refreshed?13:12}</small></button>
                {sourcesOpen&&<div className={styles.sourceList}>{([['wifi','α7 V · Wi-Fi'],['card','SDXC · 读卡器']] as const).map(([value,label])=><button key={value} aria-pressed={source===value} onClick={()=>{setSource(value);setSlot(0);setOffline(false);setSourcesOpen(false);setProjectView(null);}}>{value==="wifi"?<Camera/>:<HardDrive/>}<span>{label}</span>{source===value&&<Check/>}</button>)}</div>}
                {source==="wifi"&&<SegmentControl options={[{value:0,label:"合并"},{value:1,label:"卡 1"},{value:2,label:"卡 2"}]} value={slot} label="演示设备卡槽" disabled={importing} onChange={value=>{setSlot(value);setProjectView(null);}}/>}
              </div>
              <div className={styles.filterPanel}>
                <div className={styles.panelHeading}><span>筛选</span>{scopeFiltered&&<button className={styles.clearFilters} onClick={clearFilters} disabled={importing}>清除</button>}</div>
                <label className={styles.filterLabel}>显示</label><SegmentControl options={[{value:"all",label:"全部"},{value:"new",label:"未导入"}]} value={onlyNew?"new":"all"} label="演示显示范围" disabled={importing} onChange={value=>{setOnlyNew(value==="new");setProjectView(null);}}/>
                <div className={styles.filterLabel}>项目类型</div><div className={styles.projectType} title="新建项目时选择；导入时只取这一类素材">{scopeTitles[scope]}</div>
                {scope!=="videos"&&<><label className={styles.filterLabel}>照片格式</label><div className={`${styles.segmentGroup} ${styles.multiSegment}`} role="group" aria-label="演示照片格式" style={{"--segment-count":2} as CSSProperties}>{([['raw','RAW'],['photo','JPG/HIF']] as const).map(([key,label])=><button key={key} className={types[key]?styles.segmentOn:""} aria-pressed={types[key]} onClick={()=>{setTypes(current=>({...current,[key]:!current[key]}));setProjectView(null);}} disabled={importing}>{label}</button>)}</div></>}
                <div className={styles.searchRow}><label className={styles.search}><Search/><input value={query} onChange={event=>{setQuery(event.target.value);setProjectView(null);}} placeholder="搜索文件名或设备" aria-label="搜索演示素材" disabled={importing}/></label><label className={styles.markMenu}><Tag/><select value={mark} aria-label="按演示标记筛选" disabled={importing} onChange={event=>{setMark(event.target.value);setProjectView(null);}}><option value="all">标记</option><option value="marked">有标记</option>{[1,2,3,4,5].map(stars=><option key={stars} value={`stars:${stars}`}>至少 {stars} 星</option>)}<option value="shot">Shot Mark</option><option value="rejected">删除标记</option></select></label></div>
                <div className={styles.dateHeading}>日期</div>
                <div className={styles.dateList}>{dates.map(date=>{const ids=filtered.filter(id=>shots[id].day===date.id);return <button className={`${styles.dayRow} ${day===date.id&&projectView===null?styles.dayOn:""}`} aria-pressed={day===date.id&&projectView===null} disabled={importing} onClick={()=>chooseDate(date.id)} key={date.id}><span>{date.label}</span><small>{ids.length}</small></button>;})}</div>
                {refreshed&&<p className={styles.refreshNote} role="status">发现 1 个新片段 · 保留当前选择</p>}
              </div>
            </aside>

            <section className={styles.main} aria-label="演示素材浏览">
              <header className={styles.browseHeader}><div className={styles.countHeading}><strong>{projectView!==null?projectNames[activeProject]:!visible.length?"没有符合条件的素材":fresh.length?countText(fresh).replace("张照片","张新照片").replace("个片段","个新片段"):"当前素材均已导入"}</strong>{projectView!==null&&<span>已导入素材</span>}</div><input className={styles.thumbSlider} type="range" min="110" max="320" value={thumbSize} onChange={event=>setThumbSize(Number(event.target.value))} aria-label="演示缩略图大小" aria-valuetext={`${thumbSize} 像素`} style={{"--range-progress":`${(thumbSize-110)/210*100}%`} as CSSProperties}/></header>
              {offline&&<div className={styles.offlineBanner} role="status"><RefreshCw/><strong>相机已断开</strong><span>已保留当前选择</span><button onClick={()=>setOffline(false)}>重新连接</button></div>}
              <div className={styles.library}>
                <div className={styles.dayHeader}><strong>{projectView!==null?(projectView==="photos"?"照片":projectView==="videos"?"视频":"项目素材"):dates.find(date=>date.id===day)?.label}</strong>{projectView===null&&<button disabled={importing||!visible.length} onClick={selectDay}>{allPicked?"取消选择":"全选当前范围"}</button>}</div>
                <div className={styles.grid} style={{"--thumb-size":`${thumbSize}px`} as CSSProperties}>{visible.map((id,position)=>{
                  const shot=shots[id],isSelected=selected.has(id);
                  return <div className={styles.cell} key={shot.name}>
                    <button draggable={!importing&&projectView===null} onDragStart={event=>{if(!isSelected){event.preventDefault();return;}event.dataTransfer.setData("application/x-minidit-demo","selection");event.dataTransfer.effectAllowed="copy";}} className={`${styles.thumbnail} ${isSelected?styles.thumbnailSelected:""}`} aria-label={`${shot.name}，${isSelected?"已选择，点击取消":"点击选择"}`} aria-pressed={isSelected} disabled={importing} onClick={()=>toggle(id)} onDoubleClick={()=>setPreview(id)} onKeyDown={event=>{if(event.key===" "){event.preventDefault();setPreview(id);}}}>
                      <img src={`images/thumbs/${shot.image}.webp`} alt="" width={480} height={320} style={{objectPosition:shot.position}} loading={position<6?undefined:"lazy"}/>
                      <span className={styles.formatBadge}>{badge(id)}</span>
                      {id===0||id===4||id===6?<span className={styles.markBadge}>{id===6?"◆ 2":id===0?"★★★★":"★★★"}</span>:null}
                      {shot.video&&<span className={styles.playIcon}>▶</span>}{isSelected&&<span className={styles.selectionCheck}><Check/></span>}
                      {(copied.has(id)||proxyCopies.has(id))&&<span className={styles.copyBadge}><Check/>{copied.has(id)?backedCopies.has(id)?"已备份":"已导入":"仅代理"}</span>}
                    </button><div className={styles.fileMeta}><span>{shot.name}</span></div>
                  </div>;
                })}</div>
                {!visible.length&&<div className={styles.emptyState}><ImageIcon/><strong>{projectView!==null?"这个项目还没有导入素材":"无符合筛选条件的素材"}</strong><span>{projectView!==null?"选中日期和素材，再导入或拖入此项目。":"调整中栏的日期、格式或标记筛选。"}</span></div>}
              </div>
              {projectView===null&&<div className={styles.barContainer}><div className={styles.importBar} ref={importBarRef}>
                <GlassHighlights hostRef={importBarRef} dark={dark}/>
                <div className={styles.importText} aria-live="polite"><strong>{importing?"正在演示导入…":result?"演示导入完成":picked.length?`已选 ${countText(picked)} · ${pickedSize} MB`:"选择日期或点选素材"}</strong><span>{importing?"复制、校验，并记录项目归属":result??(offline?"重新连接后可继续导入":`${fileCount} 个文件 · ${projectNames[activeProject]}`)}</span></div>
                <div className={styles.barActions} data-glass-actions>{selectedVideo&&<button className={`${styles.glassButton} ${proxy?styles.glassOn:""}`} aria-pressed={proxy} onClick={()=>setProxy(!proxy)} disabled={importing}>仅代理</button>}
                  <button className={`${styles.glassButton} ${backup?styles.glassOn:""}`} aria-pressed={backup} onClick={()=>setBackup(!backup)} disabled={importing}>备份</button>
                  <div className={styles.moreWrapper}><button className={`${styles.glassButton} ${styles.moreButton}`} aria-label="查看演示存放位置" aria-expanded={pathsOpen} onClick={()=>{setPathsOpen(!pathsOpen);setOptionsOpen(false);}}><Folder/></button>{pathsOpen&&<div className={styles.optionsMenu}><strong>本次存放位置 · 示例</strong><span>照片 / {projectNames[activeProject]}</span><span>视频 / {projectNames[activeProject]}</span>{backup&&<span>Backup / 照片与视频</span>}</div>}</div>
                  <div className={styles.moreWrapper}><button className={`${styles.glassButton} ${styles.moreButton}`} aria-label="演示导入选项" aria-expanded={optionsOpen} onClick={()=>{setOptionsOpen(!optionsOpen);setPathsOpen(false);}} disabled={importing}><MoreHorizontal/></button>{optionsOpen&&<div className={styles.optionsMenu}><span><Check/>保留卡上原片</span><button onClick={()=>{setOffline(!offline);setOptionsOpen(false);}}>{offline?"恢复演示连接":"模拟相机断线"}</button></div>}</div>
                  <button className={`${styles.glassButton} ${styles.importButton}`} aria-label="演示导入" onClick={()=>beginImport()} disabled={importing||offline||!picked.length}>{importing?<span className={styles.spinner}/>:"导入"}</button>
                </div>
              </div></div>}
            </section>
          </div>
        </div>
      </div>
      <figcaption className={styles.caption}><MousePointer2/><span>试试筛选素材，或将选中的素材拖入左侧项目。<span className={styles.mobileHint}>小屏可左右滑动查看完整界面。</span></span></figcaption>
    </figure>
    <dialog ref={lightboxRef} className={styles.lightbox} aria-label={preview!==null&&shots[preview].video?"视频预览演示":"照片预览演示"}
      onClose={()=>setPreview(null)} onClick={event=>{if(event.target===event.currentTarget)event.currentTarget.close();}}>
      {preview!==null&&<><button type="button" className={styles.closePreview} aria-label="关闭预览" onClick={()=>lightboxRef.current?.close()}><X/></button><DemoPreview id={preview}/><div className={styles.previewBar}><span>{shots[preview].name} · 示例素材</span><button type="button" onClick={()=>toggle(preview)}>{selected.has(preview)?<Check/>:<Plus/>}{selected.has(preview)?"已选择":"选择"}</button></div></>}
    </dialog>
  </>;
}

function DemoPreview({ id }: { id: number }) {
  const shot = shots[id];
  const videoRef = useRef<HTMLVideoElement>(null);
  const [seconds, setSeconds] = useState(0);
  const [jump, setJump] = useState("");
  const [error, setError] = useState("");
  function timecode(time: number) {
    const frames = 4 + Math.floor(time * 25 + 0.001);
    const total = 3 + Math.floor(frames / 25);
    return `01:02:${String(total).padStart(2, "0")}:${String(frames % 25).padStart(2, "0")}`;
  }
  function jumpTo() {
    const digits = jump.replace(/[:;]/g, "");
    if (!/^\d{8}$/.test(digits)) { setError("请输入时间码，例如 01:02:08:04"); return; }
    const [h, m, s, f] = [0, 2, 4, 6].map(index => Number(digits.slice(index, index + 2)));
    const target = (h * 3600 + m * 60 + s - 3723) + (f - 4) / 25;
    const duration = videoRef.current?.duration ?? (id === 6 ? 18 : 12);
    if (m > 59 || s > 59 || f > 24 || target < 0 || target >= duration) { setError("时间码超出示例片段范围"); return; }
    if (videoRef.current) videoRef.current.currentTime = target;
    setSeconds(target); setError("");
  }
  if (!shot.video) return <img className={styles.previewImage} src={`images/${shot.image}.jpg`} alt={`${shot.name} 示例素材`} onClick={event => event.stopPropagation()} />;
  return <div className={styles.videoPreview} onClick={event => event.stopPropagation()}>
    <video ref={videoRef} src={`videos/${id === 6 ? "coast" : "cliffs"}.mp4`} poster={`images/${shot.image}.jpg`} controls playsInline preload="metadata" onTimeUpdate={event => setSeconds(event.currentTarget.currentTime)} aria-label={`${shot.name} 演示片段`} />
    <div className={styles.timecodeControls}><span>TC <strong>{timecode(seconds)}</strong> · NDF</span><label><span className={styles.srOnly}>定位到时间码</span><input placeholder="01:02:08:04" aria-label="演示时间码定位" value={jump} onChange={event => setJump(event.target.value)} onKeyDown={event => { if (event.key === "Enter") jumpTo(); }} /></label><button onClick={jumpTo}>跳转</button>{id === 6 && <button onClick={() => { if (videoRef.current) videoRef.current.currentTime = 5; setSeconds(5); }}>◆ Shot Mark</button>}</div>
    {error && <p className={styles.jumpError} role="status">{error}</p>}
    <p className={styles.previewNote}>交互与时间码为演示；示例片段由 Unsplash 照片制作。</p>
  </div>;
}
