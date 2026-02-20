# Swift Fullstack (iPhone + Swift Backend)

`fridge-mvp`의 핵심 기능(로그인 제외)을 Swift 기반으로 옮긴 샘플입니다.

## 구성

- `backend/` : Vapor API 서버
- `ios/` : SwiftUI iOS 앱 (XcodeGen 프로젝트)

## 1) 백엔드 실행

```bash
cd backend
swift run Run
```

기본 주소: `http://127.0.0.1:8080`

### 제공 API

- `GET /health`
- `GET /items`, `POST /items`, `DELETE /items/:id`
- `GET /shopping`, `POST /shopping`, `PATCH /shopping/:id/toggle`, `DELETE /shopping/:id`
- `GET /recipes/recommendations`
- `GET /essential`, `POST /essential`, `DELETE /essential/:name`

## 2) iOS 앱 실행

```bash
cd ../ios
xcodegen generate
open FridgeMVPiOS.xcodeproj
```

- 시뮬레이터에서 실행 후, 설정 탭에서 백엔드 URL 확인
- 기본값: `http://127.0.0.1:8080/`

> 실기기 테스트 시에는 Mac의 로컬 IP(예: `http://192.168.0.xx:8080/`)로 바꿔 주세요.

## 테스트

```bash
cd backend
swift test
```

## 참고

- 현재 저장소는 서버 메모리 기반 저장입니다(재시작 시 초기화).
- 다음 단계: SQLite(Fluent) 영속화, OAuth, 푸시알림(APNs) 확장.
