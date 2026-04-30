# AutoStack-Epoxy

Ubuntu 24.04 LTS 환경에서 OpenStack Epoxy를 **Controller / Compute / Block** 3-노드 구성으로 자동 설치합니다.

---

## 구성 요소

| 노드 | 설치 서비스 |
|------|------------|
| **Controller** | Keystone, Glance, Placement, Nova-API, Neutron-Server, Horizon, Cinder-API |
| **Compute** | Nova-Compute, Neutron-OVS-Agent |
| **Block** | Cinder-Volume (LVM + iSCSI) |

**공통 인프라 (Controller):** MariaDB, RabbitMQ, Memcached, etcd

**네트워크 드라이버:** OpenVSwitch (ML2) + VXLAN

---

## 요구 사항

### VM 사양 (권장)

| 항목 | Controller | Compute | Block |
|------|-----------|---------|-------|
| OS | Ubuntu 24.04 LTS | Ubuntu 24.04 LTS | Ubuntu 24.04 LTS |
| RAM | 8GB 이상 | 4GB 이상 | 2GB 이상 |
| CPU | 2코어 이상 | 2코어 이상 (VT-x 권장) | 1코어 이상 |
| 디스크 | 100GB | 100GB | 100GB + 추가 디스크 (LVM용) |
| NIC | 2개 | 2개 | 1개 이상 |

### 네트워크 인터페이스

각 VM에 NIC 2개 필요:

| NIC | 용도 | 예시 |
|-----|------|------|
| 첫 번째 NIC | Management (관리망) | `10.0.0.0/24` |
| 두 번째 NIC | Provider (외부망, IP 미할당) | `192.168.2.0/24` |

> VMware 기준: NAT → Management, Host-only → Provider

### Block 노드 추가 디스크

Cinder LVM 볼륨 전용 미포맷 디스크가 별도로 필요합니다. (예: `/dev/sdb`)

---

## 빠른 시작

### 1단계: 스크립트 다운로드 (전 노드)

```bash
sudo su
cd /opt
git clone <repo_url> AutoStack-Epoxy
cd AutoStack-Epoxy
chmod +x setup.sh preflight.sh deploy.sh scripts/*.sh
```

### 2단계: 환경 설정 마법사 실행 (전 노드, 각각)

> **네트워크 사전 설정 불필요** — Ubuntu 설치 직후 초기 상태에서 바로 실행 가능합니다.

```bash
sudo ./setup.sh
```

마법사 진행 순서:
1. Management NIC 선택 (자동 스캔 목록에서 선택)
2. Provider NIC 선택
3. Management 서브넷 / 게이트웨이 입력
4. Provider 서브넷 / 게이트웨이 / 할당 풀 입력
5. 노드 역할 범위 설정 (기본값 사용 가능)
6. 공통 패스워드 입력
7. 이 노드의 고정 IP 입력 (현재 IP 감지 시 제안값으로 표시)
8. 역할 자동 판별 및 확인

설정 결과는 `/etc/AutoStack-Epoxy/env.sh` 에 저장됩니다.

> 실제 네트워크 적용(`netplan apply`)은 `deploy.sh` 실행 시 `00_common.sh` 단계에서 수행됩니다.

### 3단계: 환경 검증 (전 노드, 각각)

```bash
sudo ./preflight.sh
```

모든 항목이 `[✓]` 또는 `[!]` 이어야 배포를 진행할 수 있습니다.

### 4단계: 배포 (전 노드, 각각)

**순서가 중요합니다. Controller → Compute → Block 순으로 실행하세요.**

```bash
sudo ./deploy.sh
```

역할에 따라 해당 스크립트를 자동으로 순서대로 실행합니다.

---

## 설치 순서 (자동 처리)

```
Controller:  00_common → 01_keystone → 02_glance → 03_placement
             → 04_nova → 05_neutron → 06_horizon → 07_cinder

Compute:     00_common → 04_nova → 05_neutron

Block:       00_common → 07_cinder
```

> Compute 설치 완료 후 Controller에서 `nova-manage cell_v2 discover_hosts` 가 자동 실행되지 않습니다.
> Compute 배포 완료 후 Controller에서 아래 명령어를 실행해 Compute 노드를 등록하세요:
> ```bash
> sudo ./scripts/04_nova.sh discover
> ```

---

## 파일 구조

```
AutoStack-Epoxy/
├── setup.sh              # 환경 설정 마법사
├── preflight.sh          # 배포 전 환경 검증
├── deploy.sh             # 역할별 자동 배포
├── scripts/
│   ├── 00_common.sh      # 공통: hostname, hosts, netplan, NTP, 인프라
│   ├── 01_keystone.sh    # Identity 서비스
│   ├── 02_glance.sh      # Image 서비스
│   ├── 03_placement.sh   # Placement API
│   ├── 04_nova.sh        # Compute 서비스 (Controller/Compute 분기)
│   ├── 05_neutron.sh     # Networking 서비스 (Controller/Compute 분기)
│   ├── 06_horizon.sh     # Dashboard
│   └── 07_cinder.sh      # Block Storage (Controller/Block 분기)
└── lib/
    ├── nic.sh            # NIC 자동 감지 함수
    ├── role.sh           # IP 기반 역할 판별 함수
    ├── check.sh          # 환경 검증 함수
    └── ui.sh             # 출력 헬퍼 (색상, 프롬프트)
```

---

## 환경 변수 (`/etc/AutoStack-Epoxy/env.sh`)

`setup.sh` 실행 후 생성됩니다. 직접 수정도 가능합니다.

| 변수 | 설명 | 예시 |
|------|------|------|
| `MGMT_IF` | Management NIC 이름 | `ens33` |
| `PROVIDER_IF` | Provider NIC 이름 | `ens34` |
| `MGMT_CIDR` | Management 서브넷 | `10.0.0.0/24` |
| `MGMT_GW` | Management 게이트웨이 | `10.0.0.2` |
| `PROVIDER_CIDR` | Provider 서브넷 | `192.168.2.0/24` |
| `PROVIDER_GW` | Provider 게이트웨이 | `192.168.2.2` |
| `PROVIDER_POOL_START` | Floating IP 시작 | `192.168.2.200` |
| `PROVIDER_POOL_END` | Floating IP 끝 | `192.168.2.250` |
| `CONTROLLER_RANGE` | Controller IP 범위 (마지막 옥텟) | `10-19` |
| `COMPUTE_RANGE` | Compute IP 범위 | `20-99` |
| `BLOCK_RANGE` | Block IP 범위 | `100-200` |
| `CONTROLLER_IP` | Controller 노드 IP | `10.0.0.11` |
| `MY_ROLE` | 이 노드의 역할 | `compute` |
| `MY_IP` | 이 노드의 Management IP | `10.0.0.31` |
| `MY_HOSTNAME` | 이 노드의 hostname | `compute01` |
| `COMMON_PASS` | 공통 패스워드 | _(입력값)_ |

---

## preflight 검증 항목

| 항목 | 기준 | 역할 |
|------|------|------|
| OS 버전 | Ubuntu 24.04 | 전체 |
| Management NIC 존재 | 선택한 NIC 실재 여부 | 전체 |
| Management IP 할당 | NIC에 IP 존재 여부 | 전체 |
| Provider NIC 존재 | 선택한 NIC 실재 여부 | 전체 |
| Promiscuous mode | Provider NIC promisc 가능 여부 | 전체 |
| Bridge 생성 지원 | 커널 bridge 모듈 | 전체 |
| VXLAN 지원 | 커널 vxlan 모듈 | 전체 |
| IP Forwarding | `net.ipv4.ip_forward` | 전체 |
| Management 게이트웨이 응답 | ping 응답 여부 | 전체 |
| RAM | Controller 8GB / Compute 4GB / Block 2GB | 역할별 |
| KVM 지원 | `/dev/kvm` 존재 여부 (경고만) | Compute |
| 미사용 디스크 존재 | LVM PV용 추가 디스크 | Block |
| 포트 충돌 | 5000, 8774, 8778, 9292, 9696 | Controller |

> KVM 미지원 시 `virt_type=qemu` 로 자동 설정되어 배포는 계속됩니다. (성능 저하)

---

## 알려진 제한사항

- Controller 단일 노드 구성만 지원 (HA 미지원)
- Swift(Object Storage) 미포함
- 멀티 Controller는 지원하지 않음
- 배포 후 노드 추가 시 해당 노드에서 `setup.sh` → `deploy.sh` 실행, Controller에서 `discover_hosts` 수동 실행 필요
