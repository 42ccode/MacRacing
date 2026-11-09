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

仓库地址为 `git@github.com:42ccode/MacRacing.git`，主分支为 `main`。

首次克隆后启用本项目的本地推送检查：

```sh
git config core.hooksPath .githooks
python3 Tools/check_publication.py HEAD v1.4.0
git push origin main v1.4.0
```

当前工作副本已启用检查钩子，并使用 GitHub noreply 邮箱作为提交和标签署名。新工作副本请自行配置合适的公开署名；检查器要求使用 `@users.noreply.github.com` 邮箱。

`.gitignore` 排除构建产物、签名私钥、云凭据、本地代理配置、练习记录、日志和历史备份。忽略规则不会移除已经提交的历史内容，所以发布检查会同时扫描暂存区、所选分支的全部历史和标签元数据。它会阻止常见令牌、私钥、含凭据的 URL、本地个人路径、不适合公开的 Git 邮箱，以及被排除文件进入推送。

检查器是启发式防线，不能替代人工检查截图、素材元数据和新引入文件，也不能证明绝对不存在敏感信息。推送钩子只在已配置的本地副本生效。

## 打包版本

```sh
./test.sh
./build.sh
python3 Tools/package_release.py
```

当前输出为 `dist/APEX-Lab-1.4-arm64.zip`。将 ZIP 作为 GitHub Release 附件上传，不提交到源码仓库。构建脚本使用本地临时签名；公开分发所需的 Developer ID 签名与公证尚未配置。

发布时保留 `Assets/THIRD-PARTY-NOTICES.md`、素材元数据和署名。项目原创代码的开源许可证尚未选定；素材分别采用其注明的许可证，不由未来的代码许可证覆盖。
