import type { Metadata, Viewport } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "MiniDiT — 把时间留给创作",
  description: "面向摄影与视频创作者，围绕拍摄项目组织多次导入，分别设置照片与视频的存放规则，提供内容核对、第二份备份、ASC MHL 清单与后期软件交接。当前版本适配 Sony α 相机。",
  metadataBase: new URL(process.env.NEXT_PUBLIC_SITE_URL ?? "https://minidit-camera-to-creation.corkymyna.chatgpt.site/"),
  openGraph: {
    title: "MiniDiT — 把时间留给创作",
    description: "围绕拍摄项目组织素材，用内容核对与 ASC MHL 留下校验依据，再将照片、原片、代理与拍摄信息交给后期。",
    locale: "zh_CN",
    type: "website",
  },
  // 让支持的浏览器跟随系统的文字大小设置（字号都用 rem）。
  other: { "text-scale": "scale" },
  icons: {
    icon: "favicon.svg",
    shortcut: "favicon.svg",
  },
};

// 告诉浏览器页面支持浅色和深色，首屏就用对应的底色，避免闪白。
export const viewport: Viewport = {
  colorScheme: "light dark",
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#ffffff" },
    { media: "(prefers-color-scheme: dark)", color: "#121212" },
  ],
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="zh-CN">
      <body className="antialiased">{children}</body>
    </html>
  );
}
