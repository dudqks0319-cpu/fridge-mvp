# 우리집 냉장고를 부탁해 (fridge-mvp)

iPhone 스타일(B타입) UI로 만든 냉장고 관리 MVP입니다.

## 핵심 기능

- 홈/냉장고/추천/장보기/설정 하단 5탭
- 재료 빠른 등록 + 직접 등록
- 유통기한 D-day 표시(임박/경과)
- 부족 재료 장보기 추가 + 쿠팡 검색 링크
- 계량 모드 토글(간편 숟가락 / 정밀 ml·g)
- 필수 재료 부족 알림

## 실행

```bash
pnpm install
pnpm dev
```

- 개발 서버: `http://localhost:3000`

## 테스트/검증

```bash
pnpm test
pnpm lint
pnpm build
```

## 배포

- Vercel 배포를 기준으로 운영합니다.
- 완료 후 GitHub + Vercel 링크를 함께 공유합니다.
