import type { NextConfig } from "next";

// GitHub Pages 静态导出：由 STATIC_EXPORT=1 打开，产物在 out/。
// 项目页地址是 https://751k.github.io/MiniDiT/，所以部署时要带 basePath；
// 以后换自定义域名时，把 NEXT_PUBLIC_BASE_PATH 留空即可。
const staticExport = process.env.STATIC_EXPORT === "1";
const basePath = process.env.NEXT_PUBLIC_BASE_PATH ?? "";

const nextConfig: NextConfig = {
  ...(staticExport ? { output: "export" as const } : {}),
  ...(basePath ? { basePath } : {}),
  images: { unoptimized: true },
};

export default nextConfig;
