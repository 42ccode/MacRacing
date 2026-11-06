# Git 与 GitHub 发布

本地仓库使用 `main` 分支。源码、测试、构建工具、文档及运行必需的素材纳入版本控制；`.build/`、`dist/`、本地练习数据和环境配置文件已忽略。

## 从源码运行

在 Apple Silicon Mac 上安装 Xcode 命令行工具后，从仓库根目录执行：

```sh
./build.sh --run
./test.sh
```

素材直接保存在仓库内，当前不依赖 Git LFS。请避免反复提交大型素材的中间版本。

## 连接 GitHub

在 GitHub 创建空仓库，不自动添加 README、许可证或 `.gitignore`。将下面的 `OWNER` 和 `REPOSITORY` 替换为实际名称：

```sh
git remote add origin https://github.com/OWNER/REPOSITORY.git
git push -u origin main
```

若已配置 `origin`，先用 `git remote -v` 确认地址。提交身份沿用本机 Git 配置；首次公开推送前可用 `git log -1 --format=fuller` 确认署名。

## 打包版本

```sh
./test.sh
./build.sh
python3 Tools/package_release.py
```

当前输出为 `dist/APEX-Lab-0.4-arm64.zip`。将 ZIP 作为 GitHub Release 附件上传，不提交到源码仓库。构建脚本使用本地临时签名；公开分发所需的 Developer ID 签名与公证尚未配置。

发布时保留 `Assets/THIRD-PARTY-NOTICES.md`、素材元数据和署名。项目原创代码的开源许可证尚未选定；素材分别采用其注明的许可证，不由未来的代码许可证覆盖。
