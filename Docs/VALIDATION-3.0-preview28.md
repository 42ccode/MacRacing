# APEX Lab 3.0 Preview 28 燃油车传动

| 车型 | 前进挡 | 限转 | 峰值扭矩 | 峰值功率 |
| --- | ---: | ---: | ---: | ---: |
| Ferrari 458 Spider | 7 | 9,200 rpm | 540 N·m @ 6,000 rpm | 416 kW @ 9,000 rpm |
| Porsche 911 Carrera 4S | 8 | 7,500 rpm | 530 N·m @ 2,300–5,000 rpm | 331 kW @ 6,500 rpm |
| BMW M3 E30 2.3 | 5 | 7,250 rpm | 240 N·m @ 4,750 rpm | 147 kW @ 6,750 rpm |
| Lamborghini Centenario | 7 | 8,600 rpm | 690 N·m @ 5,500 rpm | 566 kW @ 8,500 rpm |
| Lotus Elise S1 1.8 | 5 | 7,000 rpm | 165 N·m @ 3,000 rpm | 88 kW @ 5,500 rpm |

原厂峰值之间的全油门扭矩用估算曲线插值，输出受原厂峰值功率约束。911 的单一有效终传按后桥和常啮合齿轮折算。Centenario 采用同系 Aventador ISR 公开齿比及后桥终传。E30 的峰值取 BMW 早期公路版资料，限转以同代维修手册数据为参考。40 年纪念资料与后期维修文档中的 E30 动力数据对应不同版本。

- Ferrari 采用车主手册的规格组合。 [458 Spider 手册，第 27 页](https://di-uploads-development.s3.us-east-1.amazonaws.com/ferrarioflongisland/uploads/2020/02/458spider.pdf)
- Porsche 采用 2020 款 Carrera 4S PDK。 [Porsche 911 厂方规格](https://newsroom.porsche.com/dam/jcr%3Ad5712d5c-b376-41d9-8201-09731162e143/2020_911_Carrera_S_and_911_Carrera_4S_US_specifications.pdf)
- BMW 使用 2.3 升公路版齿比。 [BMW AG 规格表](https://s3.bimmerfile.com.s3.amazonaws.com/wp-content/uploads/2012/05/40Jahre_M_Fahrzeuge_gb.pdf) · [BMW 维修资料](https://workshop-manuals.com/bmw/3_series_e30/m3_s14_sal/3_technical_data/11__engine_(s14)/0__engine_general/1_td__engine_in_general_s14_m3/)
- Centenario 使用厂方动力数据与供应商公布的同系变速器。 [Lamborghini 车型资料](https://www.lamborghini.com/en-en/masterpieces/centenario) · [峰值扭矩](https://www.lamborghini-sg.ch/models/few-off/few-off-centenario) · [转速上限](https://preview.thenewsmarket.com/Previews/lamb/DocumentAssets/423020_v3.pdf) · [Dana ISR 齿比](https://www.dana.com/globalassets/resource-library/light-vehicle/spec-sheets/dana-specsheet-longitudinaltransmission.pdf) · [Aventador 原厂终传规格](https://www.auto-brochures.com/makes/Lamborghini/aventador/Lamborghini_int%20Aventador_2019-svj.pdf)
- Lotus 使用标准 S1 1.8，变速箱为 C6BP。 [Lotus Service Notes TDM / TDL](https://manualzilla.com/doc/6035703/lotus-elise-s1-service-manual)

传递扭矩恢复时间是模拟参数。双离合较短且保留部分传力，E30 和 Elise 的换挡更长。动力声由各车已交付的驱动载荷驱动。自动换挡辅助在任何挡位下使用相同的机械参数。

平直干地静止起步、默认辅助、全油门，Ferrari 458 的 0–100 km/h 为 5.12 秒，911 为 3.65 秒，E30 为 6.95 秒，Centenario 为 3.62 秒，Elise 为 7.48 秒。同条件下 MX-5 为 7.20 秒、Honda e 为 8.06 秒。起步模型、轮胎有效滚动半径与实车性能仍有差别，尤其是 458 的原厂 0–100 km/h 指标低于 3.5 秒。
