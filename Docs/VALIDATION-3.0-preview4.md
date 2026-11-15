# APEX Lab 3.0 Preview 4 验证

本轮集中调整刹车、转向和手柄震动。用 Preview 3 和 Preview 4 在相同的初速、路面和输入下比较，车辆从 108 km/h 开始，各轮初始转速与车速匹配。

| 工况 | Preview 3 | Preview 4 |
| --- | ---: | ---: |
| MX-5 渐进档，25% 踩刹 25 ms 后的制动压力 | 3.7% | 1.5% |
| MX-5 渐进档，50% 踩刹 500 ms 后的减速度 | 0.509 G | 0.539 G |
| MX-5 渐进档，全刹 500 ms 后的减速度 | 0.923 G | 0.923 G |
| MX-5 轻带刹入弯后完全松开 83 ms，剩余压力 | 0.18% | 0.06% |
| Centenario 标准档，7% 转向输入 50 ms 后的齿条转角 | 0.143° | 0.125° |
| Centenario 标准档，65% 转向输入 50 ms 后的齿条转角 | 3.122° | 3.237° |

528 项软件检查、32 项原生练习回归和 81 项界面回归通过。检查覆盖轻触与紧急制动、带刹入弯和卸压、回正和反打，以及震动脉冲的幅度变化与叠加。握把合并输出保留次要信号，连续参数失败时切换到 16 档脉冲。Xbox 蓝牙马达的实际响应及主观驾驶手感留给实体设备验收。

公开资料用于确认把输入映射与车辆制动分开的思路。应用采用自己的压力曲线、齿条响应和手柄震动标定。[iRacing 控制器校准](https://support.iracing.com/support/solutions/articles/31000133335-controller-setup-and-calibration) · [Apple Core Haptics 实时参数](https://developer.apple.com/documentation/corehaptics/updating-continuous-and-transient-haptic-parameters-in-real-time)
