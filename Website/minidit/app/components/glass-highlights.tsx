"use client";

import { useEffect, useRef, type RefObject } from "react";
import { glassHighlightShader } from "./glass-highlight-shader";
import styles from "./product-demo.module.css";

// Narrow structural types keep this enhancement independent of a WebGPU SDK.
// Unsupported browsers keep the CSS material; they never need a GPU polyfill.
interface BufferHandle { destroy(): void }
interface PipelineHandle { getBindGroupLayout(index: number): unknown }
interface TextureHandle { createView(): unknown }
interface PassHandle {
  setPipeline(pipeline: PipelineHandle): void;
  setBindGroup(index: number, group: unknown): void;
  draw(vertices: number): void;
  end(): void;
}
interface EncoderHandle {
  beginRenderPass(descriptor: Record<string, unknown>): PassHandle;
  finish(): unknown;
}
interface DeviceHandle {
  queue: { writeBuffer(buffer: BufferHandle, offset: number, data: ArrayBufferView): void; submit(commands: unknown[]): void };
  createBuffer(descriptor: Record<string, unknown>): BufferHandle;
  createShaderModule(descriptor: { code: string }): unknown;
  createRenderPipeline(descriptor: Record<string, unknown>): PipelineHandle;
  createBindGroup(descriptor: Record<string, unknown>): unknown;
  createCommandEncoder(): EncoderHandle;
  pushErrorScope(filter: string): void;
  popErrorScope(): Promise<{ message: string } | null>;
  lost: Promise<unknown>;
}
interface AdapterHandle { requestDevice(): Promise<DeviceHandle> }
interface CanvasHandle {
  configure(configuration: Record<string, unknown>): void;
  getConfiguration(): { toneMapping?: { mode?: string } } | null;
  getCurrentTexture(): TextureHandle;
  unconfigure(): void;
}

let sharedDevice: Promise<DeviceHandle | null> | null = null;
function requestDevice() {
  if (!sharedDevice) {
    sharedDevice = (async () => {
      const gpu = (navigator as Navigator & { gpu?: { requestAdapter(): Promise<AdapterHandle | null> } }).gpu;
      const adapter = await gpu?.requestAdapter();
      if (!adapter) return null;
      const device = await adapter.requestDevice();
      void device.lost.then(() => { sharedDevice = null; });
      return device;
    })().catch(() => null);
  }
  return sharedDevice;
}

export default function GlassHighlights({ hostRef, dark }: {
  hostRef: RefObject<HTMLDivElement | null>;
  dark: boolean;
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const host = hostRef.current;
    const canvas = canvasRef.current;
    if (!host || !canvas || matchMedia("(prefers-reduced-transparency: reduce)").matches) return;
    let stopped = false;
    let pendingFrame = 0;
    let context: CanvasHandle | null = null;
    let uniform: BufferHandle | null = null;
    let dispose = () => {};
    host.dataset.glassRenderer = "css";
    canvas.dataset.ready = "false";

    void (async () => {
      try {
        const requestedDevice = await requestDevice();
        if (!requestedDevice || stopped) return;
        const device: DeviceHandle = requestedDevice;
        context = canvas.getContext("webgpu") as unknown as CanvasHandle | null;
        if (!context) return;
        const hdr = matchMedia("(dynamic-range: high)");
        const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)");
        const buffer = new ArrayBuffer(32 + 8 * 32);
        const floats = new Float32Array(buffer);
        const integers = new Uint32Array(buffer);
        let light: [number, number] | null = null;
        let extended = false;
        let presentedWidth = 0;
        let presentedHeight = 0;
        let presenting = false;

        const shader = device.createShaderModule({ code: glassHighlightShader });
        let pipeline: PipelineHandle;
        let group: unknown;
        let configuredFormat = "";
        uniform = device.createBuffer({ size: buffer.byteLength, usage: 0x40 | 0x08 });

        function configure() {
          if (!context || stopped || !uniform) return;
          const configuration = {
            device, format: hdr.matches ? "rgba16float" : "rgba8unorm",
            alphaMode: "premultiplied",
            colorSpace: matchMedia("(color-gamut: p3)").matches ? "display-p3" : "srgb",
            toneMapping: { mode: hdr.matches ? "extended" : "standard" },
          };
          context.configure(configuration);
          extended = hdr.matches && context.getConfiguration()?.toneMapping?.mode === "extended";
          // A display/browser without HDR presentation uses an ordinary SDR
          // surface. A floating-point buffer alone does not produce HDR.
          if (!extended && configuration.format === "rgba16float") {
            configuration.format = "rgba8unorm";
            configuration.toneMapping.mode = "standard";
            context.configure(configuration);
          }
          if (configuredFormat !== configuration.format) {
            pipeline = device.createRenderPipeline({
              layout: "auto",
              vertex: { module: shader, entryPoint: "vertex" },
              fragment: { module: shader, entryPoint: "fragment", targets: [{ format: configuration.format }] },
              primitive: { topology: "triangle-list" },
            });
            group = device.createBindGroup({ layout: pipeline.getBindGroupLayout(0), entries: [{ binding: 0, resource: { buffer: uniform } }] });
            configuredFormat = configuration.format;
          }
          canvas!.dataset.dynamicRange = extended ? "hdr" : "sdr";
          canvas!.dataset.peak = extended ? "3" : "1";
        }

        device.pushErrorScope("validation");
        configure();
        const error = await device.popErrorScope();
        if (error) throw new Error(error.message);
        if (stopped) return;

        function draw() {
          pendingFrame = 0;
          if (stopped || !context || !uniform || !host || !canvas || !presenting) return;
          try {
            const bounds = host.getBoundingClientRect();
            if (!bounds.width || !bounds.height) return;
            const ratio = Math.min(window.devicePixelRatio || 1, 2);
            const width = Math.max(1, Math.round(bounds.width * ratio));
            const height = Math.max(1, Math.round(bounds.height * ratio));
            if (width !== presentedWidth || height !== presentedHeight) {
              canvas.width = width; canvas.height = height;
              presentedWidth = width; presentedHeight = height;
            }
            floats.fill(0);
            floats[0] = width / ratio; floats[1] = height / ratio;
            floats[2] = light?.[0] ?? bounds.width * 0.2; floats[3] = light?.[1] ?? -bounds.height;
            floats[4] = extended ? 3 : 1; floats[5] = dark ? 1 : 0; floats[7] = ratio;
            const buttons = [...host.querySelectorAll<HTMLButtonElement>("[data-glass-actions] > button, [data-glass-actions] > div > button:first-child")];
            const shapes = [host, ...buttons].slice(0, 8);
            integers[6] = shapes.length;
            shapes.forEach((element, index) => {
              const rect = element.getBoundingClientRect();
              const offset = 8 + index * 8;
              floats.set([rect.x - bounds.x, rect.y - bounds.y, rect.width, rect.height], offset);
              floats[offset + 4] = index === 0 ? 0 : 1;
              floats[offset + 5] = element instanceof HTMLButtonElement && element.disabled ? 0.25 : 1;
            });
            device.queue.writeBuffer(uniform, 0, new Uint8Array(buffer));
            const encoder = device.createCommandEncoder();
            const pass = encoder.beginRenderPass({ colorAttachments: [{
              view: context.getCurrentTexture().createView(),
              clearValue: { r: 0, g: 0, b: 0, a: 0 }, loadOp: "clear", storeOp: "store",
            }] });
            pass.setPipeline(pipeline); pass.setBindGroup(0, group); pass.draw(3); pass.end();
            device.queue.submit([encoder.finish()]);
            host.dataset.glassRenderer = extended ? "webgpu-hdr" : "webgpu-sdr";
            canvas.dataset.ready = "true";
          } catch {
            host.dataset.glassRenderer = "css";
            canvas.dataset.ready = "false";
            presenting = false;
          }
        }
        function invalidate() {
          if (!stopped && !pendingFrame) pendingFrame = requestAnimationFrame(draw);
        }
        const pointer = (event: PointerEvent) => {
          if (reduceMotion.matches) return;
          const bounds = host.getBoundingClientRect();
          light = [event.clientX - bounds.x, event.clientY - bounds.y - bounds.height];
          invalidate();
        };
        const leave = () => { light = null; invalidate(); };
        const rangeChanged = () => {
          try { configure(); invalidate(); }
          catch { host.dataset.glassRenderer = "css"; canvas.dataset.ready = "false"; }
        };
        const resize = new ResizeObserver(invalidate);
        resize.observe(host);
        const mutation = new MutationObserver(invalidate);
        mutation.observe(host, { childList: true, subtree: true, attributes: true, attributeFilter: ["class", "disabled", "aria-pressed"] });
        const visible = new IntersectionObserver(entries => {
          presenting = entries.some(entry => entry.isIntersecting);
          if (presenting) invalidate();
        });
        visible.observe(host);
        host.addEventListener("pointermove", pointer);
        host.addEventListener("pointerleave", leave);
        hdr.addEventListener("change", rangeChanged);
        dispose = () => {
          resize.disconnect(); mutation.disconnect(); visible.disconnect();
          host.removeEventListener("pointermove", pointer); host.removeEventListener("pointerleave", leave);
          hdr.removeEventListener("change", rangeChanged);
        };
        void device.lost.then(() => {
          if (!stopped) { host.dataset.glassRenderer = "css"; canvas.dataset.ready = "false"; dispose(); }
        });
      } catch {
        if (!stopped) host.dataset.glassRenderer = "css";
      }
    })();
    return () => {
      stopped = true;
      cancelAnimationFrame(pendingFrame);
      dispose(); uniform?.destroy(); context?.unconfigure();
      delete host.dataset.glassRenderer;
    };
  }, [hostRef, dark]);

  return <canvas ref={canvasRef} className={styles.glassHighlights} aria-hidden="true" />;
}
