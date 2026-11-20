# APEX Lab 3.0 Preview 34 后轮转向、座舱与手柄换挡

Centenario 在低速时让后轮反向转动，进入高速后逐渐与前轮同向。按前后轴转角差求共同转动中心，再计算四条轮胎各自的方向。测试中约 29 km/h 和 155 km/h 的后轴与前轴角度比分别为 −0.190 和 +0.110。转换速度、响应和约三度后轴限位为模拟标定。 [Lamborghini 发布说明，第 3 页](https://preview.thenewsmarket.com/Previews/lamb/DocumentAssets/423020_v3.pdf)

座舱方向盘按相应齿条转向比显示。Porsche 中心为 15:1，近限位段为估算的可变比例；Elise 使用 15.8:1 并限制在 2.4 圈。部分其他车型的转向比为估算。 [Porsche 规格表](https://newsroom.porsche.com/dam/jcr%3Ad5712d5c-b376-41d9-8201-09731162e143/2020_911_Carrera_S_and_911_Carrera_4S_US_specifications.pdf) · [Lotus S1 Service Notes，HE](https://manualzilla.com/doc/6035703/lotus-elise-s1-service-manual) · [458 Spider 车型册](https://autocatalogarchive.com/wp-content/uploads/2016/05/Ferrari-458-Spider-2011.pdf)

手柄肩键和 B / X 由 macOS 按下事件入队，踏板和摇杆继续按游戏节奏读取。手动前进挡换挡时保留最近一个 160 毫秒内的请求。执行时重查降挡限转，暂停、停车维修和切车清除请求。兼容震动通道可回退到短段播放。实体 Xbox 蓝牙震感可用游戏内 F11 自验。 [Apple 按键事件说明](https://developer.apple.com/documentation/gamecontroller/gccontrollerbuttoninput)
