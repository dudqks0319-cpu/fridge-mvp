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

## OAuth 로그인 설정 (Google / Kakao / Naver)

1. Supabase 프로젝트 생성 후 **Authentication > Providers**에서 Google/Kakao/Naver를 활성화합니다.
2. 프로젝트 루트에 `.env.local` 파일을 만들고 아래 값을 넣어 주세요.

```bash
NEXT_PUBLIC_SUPABASE_URL=https://<your-project-ref>.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=<your-anon-key>
```

3. 각 OAuth 제공자 콘솔의 Redirect URL에 아래 주소를 등록합니다.

```text
https://<your-project-ref>.supabase.co/auth/v1/callback
```

> 참고: 이 앱은 로그인한 사용자별로 localStorage 키를 분리해 저장합니다.

## 테스트/검증

```bash
pnpm test
pnpm lint
pnpm build
pnpm mobile:sim:both
```

## 배포

- Vercel 배포를 기준으로 운영합니다.
- 완료 후 GitHub + Vercel 링크를 함께 공유합니다.

## 모바일 전체 스택 적용 가이드

요청한 10개 스택(FlutterFlow+Supabase, RLS, Supabase MCP, EAS, OneSignal, RevenueCat, Firebase Crashlytics/Analytics, Maestro, GitHub Actions, Fastlane) 적용 상태와 실행 방법은 아래 문서를 확인하세요.

- `docs/mobile-stack/README.md`

빠른 적용:

```bash
cp .env.mobile-stack.example .env.mobile-stack.local
pnpm mobile:secrets:apply
```

## Swift 풀스택(iPhone + Swift Backend)

로그인 제외 기능을 Swift로 이식한 버전은 `swift-fullstack/` 폴더를 확인해 주세요.

```bash
cd swift-fullstack/backend
swift run Run

cd ../ios
xcodegen generate
open FridgeMVPiOS.xcodeproj
```
