import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "우리집 냉장고를 부탁해",
  description: "냉장고 재료 기반 메뉴 추천 및 장보기 앱",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="ko">
      <body className="antialiased">
        {children}
      </body>
    </html>
  );
}
