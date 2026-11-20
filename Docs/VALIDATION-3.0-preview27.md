# APEX Lab 3.0 Preview 27 展厅、电驱与再生制动

右摇杆环绕或转头，LT / RT 缩放，Y 切换车头、侧面、车尾和座舱。鼠标可直接点击可动面，也可用下方控件一次开关全部活动部件。拖动距离超过四点时进入旋转。

911 的左右门沿原网格外皮的法线变化分离，车窗、门把手与外后视镜随门转动。Honda e 的后备厢沿上方铰链打开，尾灯固定在车身。模型试渲涵盖侧面、车头、车尾和座舱。两车继续使用原作者有授权的几何和贴图。 [车型署名与改动](../Assets/Vehicles/README.md) · [Honda e 后备厢手册](https://www.honda.co.jp/ownersmanual/webom/jpn/hondae/2020/details/136192090-5005.html)

Honda e Advance 采用 9.545:1 固定减速比、315 N·m 峰值扭矩与 113 kW 功率上限。平直干地、不使用发车控制，从静止至 100 km/h 为 8.06 秒。极速稳定在约 145.64 km/h，电机约 11,415 rpm。原厂给出的 0–100 km/h 和极速分别为 8.3 秒和 145 km/h。轮胎、风阻、初始温度和发车策略仍为模拟参数。 [厂方性能说明](https://hondanews.eu/gb/en/cars/media/pressreleases/201278/2020-honda-e-33) · [原厂减速比](https://www.honda.co.jp/auto-archive/honda-e/2024/common/pdf/honda-e_spec_list.pdf)

D 挡松油会回收，空挡仅滑行。制动踏板下由后驱电机分担一部分后制动扭矩，对比空挡液压制动，后盘受热下降。接近停车或后轮接近锁止时回收退让，持续带刹给油时驱动扭矩让位给制动。回收功率以 42 kW 为模拟上限，电池温度和荷电状态暂未接入控制。音效由被测回收强度调节既有电机录音，未使用 Honda e 实测回收声。 [Honda e 回生制动手册](https://www.honda.co.jp/ownersmanual/webom/jpn/hondae/2023/details/guide_energy.html)
