# HoopReel Phase 2 — 离线视频自动检测入球

## 1. 目标

在不依赖网络服务的前提下，对用户选取的篮球比赛视频做**离线帧分析**，
自动产出 `[Event]`（time: 秒, type: "make"），替代手工 JSON 事件文件，
直接接入既有 `EventEngine → HighlightExporter` 流水线。

---

## 2. 模块图

```
┌───────────────────────────────────────────────────────────────────┐
│                         ShotDetector                              │
│  (Detector/ShotDetector.swift — 主协调器)                          │
│                                                                   │
│  videoURL ──► FrameSampler ──► [CGImage] (每帧)                   │
│                    │                                              │
│                    ▼                                              │
│             InferenceEngine ──► [DetectionFrame]                  │
│           (CoreML / YOLO-nano)   (ball bbox, hoop bbox)           │
│                    │                                              │
│                    ▼                                              │
│             ShotRuleEngine  ──► [ShotCandidate] ──► [Event]       │
│          (轨迹分析 + 规则判定)                                      │
└───────────────────────────────────────────────────────────────────┘
```

---

## 3. 数据流

```
videoURL
  │
  ▼  AVAssetImageGenerator (targetFPS = 12)
[CGImage × N]          ← 每帧 resize 到 416×416
  │
  ▼  CoreMLInferenceEngine.infer(image:)
[DetectionFrame]       ← ball: BBox?, hoop: BBox?, confidence
  │
  ▼  BasketballShotRuleEngine.analyze(frames:)
[ShotCandidate]        ← 入球候选时间窗口
  │
  ▼  filter(confidence > threshold)
[Event]                ← {time: Double, type: "make"}
```

---

## 4. 关键数据类型

```swift
struct BBox {
    let x: Float; let y: Float     // 归一化 [0,1] 中心坐标
    let w: Float; let h: Float     // 归一化宽高
    let confidence: Float
}

struct DetectionFrame {
    let frameIndex: Int
    let timestamp:  Double         // 秒
    let ball:       BBox?          // 可能未检测到
    let hoop:       BBox?          // 固定机位可预先标定，缺省用检测值
    let players:    [BBox]         // 用于去噪（可选）
}

struct ShotCandidate {
    let startFrame:  Int
    let peakFrame:   Int           // 球进框时刻
    let confidence:  Float
    var timestamp:   Double        // = peakFrame / fps
}
```

---

## 5. 入球判定规则（固定机位单筐多人）

固定机位使得篮框位置几乎不变，可在首帧或前 30 帧做**一次性篮框标定**。

### 5.1 核心状态机

```
IDLE
  │ 球出现在 ShootingZone（篮框上方 ±2 倍框高范围）
  ▼
APPROACHING
  │ 球的 y_center 连续下降（向框方向移动）≥ 3 帧
  ▼
THROUGH_HOOP       ← ball bbox 与 hoop bbox IoU > 0.15
  │ 球消失 OR 球出现在 hoop 下方（net region）
  ▼
CONFIRMED_MAKE     → 记录 peakFrame
  │ 冷却 30 帧（2.5 s@12fps）
  ▼
IDLE
```

### 5.2 规则细节

| 规则 | 参数 | 说明 |
|------|------|------|
| ShootingZone | hoop.y ± 2×hoop.h | 只在此区域追踪球 |
| 下落判定 | Δy > 0 连续 3 帧 | 图像坐标 y 向下增大 |
| 进框判定 | IoU(ball, hoop) > 0.15 | 宽松阈值，球体可能部分遮挡 |
| Net 确认 | ball.y > hoop.y + hoop.h×0.5 | 球出现在框下方 |
| 球消失确认 | ball == nil 且上一帧 THROUGH_HOOP | 球穿网后消失 |
| 误检过滤 | ball.w < 0.02 或 > 0.15 | 过小（噪声）/过大（头/球员）排除 |
| 冷却期 | 30 帧 | 防止同一次投篮重复计数 |

### 5.3 需要的模型输出

| 输出 | 是否必须 | 说明 |
|------|----------|------|
| ball bbox + confidence | **必须** | 检测篮球位置和运动轨迹 |
| hoop bbox + confidence | **必须**（或预标定） | 判断球与框的位置关系 |
| net region bbox | 可选 | 可从 hoop bbox 推导（hoop 下方固定偏移） |
| player bboxes | 可选 | 用于去除与球员头部重叠的误检 |

**推荐模型：**
- YOLOv8-nano 或 RT-DETR-tiny，自定义训练 2 类（ball / hoop）
- 输入尺寸 416×416，A15 Bionic 推理约 12–20 ms/帧
- 导出为 CoreML `.mlpackage`（FP16 量化）

---

## 6. 性能预算

| 指标 | 目标 | 说明 |
|------|------|------|
| 采样帧率 | 12 fps | 捕获 83ms 内的入球；低于视频原始帧率 |
| 单帧推理 | ≤ 25 ms | CoreML on Neural Engine (A14+) |
| 帧提取 | ≤ 10 ms/帧 | AVAssetImageGenerator，后台队列 |
| 规则引擎 | ≤ 1 ms/帧 | 纯 Swift 内存操作 |
| **总预算/帧** | **≤ 36 ms** | 可达约 27 fps 上限，留余量 |
| 1 分钟视频 | ≤ 30 s | 720 帧 × 36ms ≈ 26 s（iPhone 14） |
| 内存峰值 | ≤ 200 MB | 滑动窗口处理，不全量缓存帧图像 |
| 后台处理 | Task + actor 隔离 | 不阻塞主线程，进度通过 AsyncStream 回调 |

---

## 7. 文件路径

```
HoopReel/
└── Detector/
    ├── ShotDetector.swift          # 主协调器（公开接口）
    ├── FrameSampler.swift          # 协议 + AVAssetImageGenerator 实现
    ├── InferenceEngine.swift       # 协议 + CoreML 占位实现
    ├── ShotRuleEngine.swift        # 协议 + 规则状态机实现
    └── Models/
        ├── DetectionFrame.swift    # 单帧检测结果
        └── ShotCandidate.swift     # 入球候选
```

---

## 8. 集成点

`ShotDetector` 产出 `[Event]` 后直接传入已有接口：

```swift
// ContentView 中替换 EventEngine.loadEvents() 的调用：
let detector = ShotDetector()
let events = try await detector.detect(videoURL: url, fps: 12)
// → 与 EventEngine.computeClipRanges(from: events, ...) 无缝对接
```
