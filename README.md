# KLMS Sync

KAIST KLMS를 Safari 로그인 세션으로 읽어 과제, 시험 일정, 공지, 첨부파일을 macOS 앱에서 정리하는 개인용 도구다. 기본 사용 흐름은 터미널 명령이 아니라 `KLMS Sync.app`에서 버튼을 누르는 방식이다.

이 프로젝트는 KAIST 또는 KLMS의 공식 도구가 아니다. 본인 계정, 본인 Mac, 본인 Safari 세션에서만 사용해야 한다.

## 빠른 시작

1. 앱을 빌드한다.

```sh
./build_klms_app.sh
```

2. 빌드가 끝나면 실제 앱은 `~/Applications/KLMS Sync.app`에 설치된다. 프로젝트 루트의 `KLMS Sync.app`은 그 앱을 가리키는 링크다.
3. Safari에서 `https://klms.kaist.ac.kr/my/`에 수동 로그인한다.
4. 앱에서 `Calendar 권한`을 한 번 허용한다.
5. 보통은 `한 번에 정리`를 누르면 된다.

첫 실행 때 macOS가 Safari, Calendar, Reminders, Notes 자동화 권한을 물으면 허용한다. 권한을 거절했다면 `시스템 설정 > 개인정보 보호 및 보안`에서 `KLMS Sync` 접근을 다시 켜야 한다.

## 앱 버튼 설명

### 작업

| 버튼 | 하는 일 | 내부 실행 |
| --- | --- | --- |
| `한 번에 정리` | 과제/시험/리마인더/캘린더를 정리하고, 공지 정리가 켜져 있으면 공지도 갱신한다. 평소 기본 버튼이다. | `run_all.sh` |
| `일정 정리` | KLMS 과제와 시험 후보를 읽고, Apple Reminders와 Calendar를 갱신한다. 첨부파일은 받지 않는다. | `sync_klms_core.sh` |
| `공지 정리` | KLMS Notice 게시판을 읽어 `KLMS 공지`, `KLMS 확인한 공지` Notes 메모를 갱신한다. 설정에서 공지 정리가 꺼져 있으면 건너뛴다. | `sync_klms_notice.sh` |
| `파일 모으기` | KLMS 첨부파일 manifest를 만들고 파일을 내려받아 학기/과목별 폴더에 정리한다. | `refresh_course_files.sh` |
| `전체 동기화` | 일정 정리, 공지 정리, 파일 모으기를 순서대로 모두 실행한다. 시간이 가장 오래 걸린다. | `run_all_full.sh` |
| `점검` | 현재 state, 공지 산출물, 파일 manifest, Calendar 개수를 확인한다. 없는 산출물은 실패가 아니라 `skipped` 또는 `missing`으로 표시한다. | `verify_sync_state.sh` |

작업 중에는 앱 상단에 현재 단계와 진행률이 표시된다. 진행률은 KLMS 페이지 수집 단계, 캘린더 동기화, 파일 다운로드 같은 주요 checkpoint를 기준으로 추정한다.

실패하면 앱이 에러 팝업을 띄우고 해당 실행의 세부 로그를 함께 보여준다. 평소에는 로그를 숨기고, 필요할 때만 `세부 보기`에서 확인한다.

### 로그인과 권한

| 버튼/토글 | 하는 일 |
| --- | --- |
| `Calendar 권한` | 앱이 Apple Calendar에 시험/헬프데스크 일정을 만들 수 있도록 권한을 요청한다. |
| `Safari 로그인` | Safari에서 KLMS 로그인 페이지를 연다. 로그인과 OTP는 기본적으로 사용자가 직접 진행한다. |
| `자동 로그인 실행` | Kaikey 기기가 등록되어 있을 때 Safari SSO/2FA 자동 진행을 한 번 시도한다. |
| `Kaikey 등록` | KAIST 2FA 등록 QR 스크린샷을 선택해 Mac을 Kaikey 인증기로 등록한다. |
| `Kaikey 자동 로그인` | 로그인 만료 시 자동으로 Kaikey 로그인을 시도할지 설정한다. `config.env`의 `KAIKEY_AUTO_LOGIN_ENABLED`를 수정한다. |
| `백그라운드 자동 실행` | LaunchAgent를 설치하거나 해제한다. 켜면 idle 상태에서 주기적으로 기본 동기화를 시도한다. |

Kaikey 상태 파일은 민감한 인증 자료다. `kaikey_state.json`이 유출되었다고 의심되면 KAIST 인증 기기를 즉시 해제/재등록한다.

### 저장 위치와 설정

| 버튼 | 하는 일 |
| --- | --- |
| `설정` | 앱 안에서 KLMS URL, 파일 저장 위치, 학기 폴더, 공지/리마인더/캘린더/Kaikey 옵션을 수정한다. 저장하면 `config.env`가 갱신된다. |
| `파일 폴더` / `폴더 열기` | 정리된 첨부파일 저장 폴더를 Finder에서 연다. |
| `세부 로그` | 최근 실행 로그를 별도 창으로 연다. 개발자용 로그는 기본 화면에 보이지 않는다. |

설정 파일을 직접 열어 수정할 필요는 없다. 앱의 `설정` 화면에서 바꾸는 것을 권장한다.

## 파일 저장 구조

파일 모으기는 기본적으로 프로젝트의 `course_files` 아래에 저장한다. 앱 설정에서 저장 루트를 바꿀 수 있고, 이는 `FILE_OUTPUT_ROOT`에 저장된다.

정리 구조는 다음과 같다.

```text
course_files/
  26S/
    과목명/
      파일명.pdf
      강의자료.pptx
```

학기 폴더는 기본값 `auto`일 때 현재 KST 날짜로 계산한다.

- 3월부터 8월까지: `YY S`, 예를 들어 2026년 봄/여름 학기는 `26S`
- 9월부터 다음 해 2월까지: `YY F`, 예를 들어 2025년 가을/겨울 학기는 `25F`

원하면 앱 설정의 `학기 폴더`에 `23F` 같은 값을 직접 넣을 수 있다.

파일명은 가능하면 KLMS가 실제로 내려준 원본 파일명을 유지한다. 같은 과목 폴더 안에 같은 이름이 있으면 `파일명 (2).pdf`처럼 중복을 피한다.

## 추천 사용 흐름

### 평소

1. Safari에서 KLMS에 로그인되어 있는지 확인한다.
2. 앱에서 `한 번에 정리`를 누른다.
3. 실패 팝업이 뜨면 안내와 로그를 확인한다.

### 첨부파일까지 정리하고 싶을 때

1. 앱에서 `파일 모으기` 또는 `전체 동기화`를 누른다.
2. 완료 후 `파일 폴더`를 눌러 Finder에서 확인한다.

### 자동 실행을 쓰고 싶을 때

1. `설정`에서 필요한 동기화 옵션을 먼저 맞춘다.
2. `백그라운드 자동 실행`을 켠다.
3. Safari 로그인이 풀리면 앱 또는 macOS 알림을 보고 다시 로그인한다.

## 주요 설정

앱 설정 화면은 아래 값을 `config.env`에 저장한다.

| 설정 | env 키 |
| --- | --- |
| KLMS 대시보드 URL | `KLMS_DASHBOARD_URL` |
| KLMS 로그인 URL | `KLMS_LOGIN_URL` |
| 파일 저장 폴더 | `FILE_OUTPUT_ROOT` |
| 학기 폴더 | `FILE_TERM_FOLDER` |
| 공지 정리 사용 | `NOTICE_SUMMARY_ENABLED` |
| Reminders 동기화 | `REMINDERS_SYNC_ENABLED` |
| 시험 Calendar 동기화 | `EXAM_CALENDAR_SYNC_ENABLED` |
| 시험 캘린더 이름 | `EXAM_CALENDAR_NAME` |
| 헬프데스크 Calendar 동기화 | `HELP_DESK_CALENDAR_SYNC_ENABLED` |
| 헬프데스크 캘린더 이름 | `HELP_DESK_CALENDAR_NAME` |
| 다운로드 보관 사본 유지 | `FILE_KEEP_FRESH_DOWNLOADS` |
| Kaikey 자동 로그인 | `KAIKEY_AUTO_LOGIN_ENABLED` |

더 세밀한 quick/full/cache 옵션은 `examples/config.env.example`을 참고해 직접 추가로 조정할 수 있다.

## CLI entrypoint

앱은 아래 스크립트를 내부적으로 호출한다. 수동 디버깅이 필요할 때만 직접 실행하면 된다.

```sh
./run_all.sh              # 한 번에 정리
./sync_klms_core.sh       # 일정 정리
./sync_klms_notice.sh     # 공지 정리
./refresh_course_files.sh # 파일 모으기
./run_all_full.sh         # 전체 동기화
./verify_sync_state.sh    # 점검
```

각 entrypoint는 작업별 lock을 사용하므로 같은 작업이 동시에 중복 실행되지 않는다. 실행 후 오래된 `runtime/tmp` 산출물은 기본적으로 자동 정리된다.

## 보안과 커밋 주의

공개 레포에는 아래 파일과 폴더를 올리지 않는다.

- `config.env`
- `manual_assignment_overrides.json`
- `kaikey_state.json`
- `runtime/`
- `course_files/`
- QR 스크린샷, 쿠키, 다운로드 파일

공개 배포 전에는 [docs/publication-checklist.md](./docs/publication-checklist.md)를 확인한다.

## 프로젝트 구조

- `build_klms_app.sh`: macOS 앱 빌드 및 `~/Applications` 설치
- `src/swift/KLMSControlCenter.swift`: 앱 UI
- `src/swift/GenerateKLMSAppIcon.swift`: 앱 아이콘 생성
- `src/sh/`: 공통 shell helper와 launchd worker
- `src/js/`: Safari/JXA 자동화, Reminders/Notes 동기화, Kaikey helper
- `src/python/`: KLMS HTML 파서, fetch backend, 파일 manifest/prune 도구
- `src/swift/`: Calendar 동기화, QR decode, Notes renderer
- `examples/`: 공개 가능한 예시 설정 파일
- `legacy/`: 예전 호환 wrapper와 디버깅 보조 스크립트

## 라이선스

라이선스는 [MIT](./LICENSE)다. Kaikey 프로토콜 구현에서 참고한 외부 코드 고지는 [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)에 둔다.
